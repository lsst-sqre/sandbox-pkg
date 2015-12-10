include ::stdlib
include ::augeas
include ::sysstat
include ::ntp
include ::irqbalance
include ::epel
include ::nginx

$user  = 'vagrant'
$group = 'vagrant'
$root  = '/opt/lsst/eupspkg'
$rsync_user = 'eupspkg'

Class['epel'] -> Package<| provider == 'yum' |>

class { 'timezone': timezone  => 'US/Pacific' }
class { 'tuned': profile      => 'virtual-host' }
class { 'selinux': mode       => 'enforcing' }
class { 'firewall': ensure    => 'stopped' }
resources { 'firewall': purge => true }

service { 'postfix':
  ensure => 'stopped',
  enable => false,
}

class { '::yum_autoupdate':
  exclude      => ['kernel*', 'nginx'],
  notify_email => false,
  action       => 'apply',
  update_cmd   => 'security',
}

$pkgs = ['git', 'tree', 'vim-enhanced', 'ack', 'rsync']
ensure_packages($pkgs)
# ensure_packages() doesn't work correctly with resource collector deps
Class['epel'] -> Package[$pkgs]

$private_dir         = '/var/private'
$ssl_cert_path       = "${private_dir}/cert_chain.pem"
$ssl_key_path        = "${private_dir}/private.key"
$ssl_dhparam_path    = "${private_dir}/dhparam.pem"
$ssl_root_chain_path = "${private_dir}/root_chain.pem"
$ssl_cert            = hiera('ssl_cert', undef)
$ssl_chain_cert      = hiera('ssl_chain_cert', undef)
$ssl_root_cert       = hiera('ssl_root_cert', undef)
$ssl_key             = hiera('ssl_key', undef)
$add_header          = hiera('add_header', undef)
$www_host            = hiera('www_host', 'pkg')
$access_log          = "/var/log/nginx/${www_host}.access.log"
$error_log           = "/var/log/nginx/${www_host}.error.log"

if $ssl_cert and $ssl_key {
  $enable_ssl = true
}

selboolean { 'httpd_can_network_connect':
  value      => on,
  persistent => true,
}

selboolean { 'httpd_setrlimit':
  value      => on,
  persistent => true,
}

# If SSL is enabled and we are catching an DNS cname, we need to redirect to
# the canonical https URL in one step.  If we do a http -> https redirect, as
# is enabled by puppet-nginx's rewrite_to_https param, the the U-A will catch
# a certificate error before getting to the redirect to the canonical name.
$raw_prepend = [
  "if ( \$host != \'${www_host}\' ) {",
  "  return 301 https://${www_host}\$request_uri;",
  '}',
]

if $enable_ssl {
  file { $private_dir:
    ensure   => directory,
    mode     => '0750',
    selrange => 's0',
    selrole  => 'object_r',
    seltype  => 'httpd_config_t',
    seluser  => 'system_u',
  }

  exec { 'openssl dhparam -out dhparam.pem 2048':
    path    => ['/usr/bin'],
    cwd     => $private_dir,
    umask   => '0433',
    creates => $ssl_dhparam_path,
  } ->
  file { $ssl_dhparam_path:
    ensure   => file,
    mode     => '0400',
    selrange => 's0',
    selrole  => 'object_r',
    seltype  => 'httpd_config_t',
    seluser  => 'system_u',
    replace  => false,
    backup   => false,
  }

  # note that nginx needs the signed cert and the CA chain in the same file
  concat { $ssl_cert_path:
    ensure   => present,
    mode     => '0444',
    selrange => 's0',
    selrole  => 'object_r',
    seltype  => 'httpd_config_t',
    seluser  => 'system_u',
    backup   => false,
    before   => Class['::nginx'],
  }
  concat::fragment { 'public - signed cert':
    target  => $ssl_cert_path,
    order   => 1,
    content => $ssl_cert,
  }
  concat::fragment { 'public - chain cert':
    target  => $ssl_cert_path,
    order   => 2,
    content => $ssl_chain_cert,
  }

  file { $ssl_key_path:
    ensure    => file,
    mode      => '0400',
    selrange  => 's0',
    selrole   => 'object_r',
    seltype   => 'httpd_config_t',
    seluser   => 'system_u',
    content   => $ssl_key,
    backup    => false,
    show_diff => false,
    before    => Class['::nginx'],
  }

  concat { $ssl_root_chain_path:
    ensure   => present,
    mode     => '0444',
    selrange => 's0',
    selrole  => 'object_r',
    seltype  => 'httpd_config_t',
    seluser  => 'system_u',
    backup   => false,
    before   => Class['::nginx'],
  }
  concat::fragment { 'root-chain - chain cert':
    target  => $ssl_root_chain_path,
    order   => 1,
    content => $ssl_chain_cert,
  }
  concat::fragment { 'root-chain - root cert':
    target  => $ssl_root_chain_path,
    order   => 2,
    content => $ssl_root_cert,
  }

  nginx::resource::vhost { "${www_host}-ssl":
    ensure               => present,
    listen_port          => 443,
    ssl                  => true,
    rewrite_to_https     => false,
    access_log           => $access_log,
    error_log            => $error_log,
    ssl_key              => $ssl_key_path,
    ssl_cert             => $ssl_cert_path,
    ssl_dhparam          => $ssl_dhparam_path,
    ssl_session_timeout  => '1d',
    ssl_cache            => 'shared:SSL:50m',
    ssl_stapling         => true,
    ssl_stapling_verify  => true,
    ssl_trusted_cert     => $ssl_root_chain_path,
    resolver             => [ '8.8.8.8', '4.4.4.4'],
    add_header           => $add_header,
    raw_prepend          => $raw_prepend,
    autoindex            => 'on',
    use_default_location => false,
    index_files          => [],
    www_root             => "${root}",
  }

  nginx::resource::upstream { 'apache-eupspkg':
    ensure  => present,
    members => [
      '127.0.0.1:8080',
    ],
  }

  # eups distrib parses the apache directory index HTML format so we are
  # proxying from nginx -> apache to provide the expected format
  nginx::resource::location { "${name}-eupspkg":
    ensure                => present,
    vhost                 => "${www_host}-ssl",
    ssl                   => true,
    ssl_only              => true,
    location              => '/eupspkg', # no trailing slash for auto redirect
    proxy                 => 'http://apache-eupspkg',
    proxy_redirect        => 'default',
    proxy_connect_timeout => '30',
  }

  # apache directory listing refers to images under /icons
  nginx::resource::location { "${name}-eupspkg-icons":
    ensure                => present,
    vhost                 => "${www_host}-ssl",
    ssl                   => true,
    ssl_only              => true,
    location              => '/icons', # no trailing slash for auto redirect
    proxy                 => 'http://apache-eupspkg',
    proxy_redirect        => 'default',
    proxy_connect_timeout => '30',
  }

}

nginx::resource::vhost { $www_host:
  ensure                => present,
  listen_port           => 80,
  ssl                   => false,
  access_log            => $access_log,
  error_log             => $error_log,
  rewrite_to_https      => $enable_ssl ? {
    true    => true,
    default => false,
  },
  use_default_location => false,
  index_files => [],
  # see comment above $raw_prepend declaration
  raw_prepend           => $enable_ssl ? {
    true     => $raw_prepend,
    default  => undef,
  },
}

class { 'apache':
  default_vhost => false,
}

apache::vhost { 'ip.example.com':
  ip      => '127.0.0.1',
  port    => '8080',
  docroot => "${root}/public/",
  aliases          => [
    {
      aliasmatch => '^/eupspkg(.*)$',
      path       => "${root}/public/\$1",
    },
  ],
}


file {[
  '/opt/lsst',
]:
  ensure => directory,
  mode   => '0755',
}

file {[
  '/opt/lsst/eupspkg',
  '/opt/lsst/eupspkg/public',
]:
  ensure => directory,
  mode   => '0775',
  owner  => $rsync_user,
  group  => $rsync_user,
}

user { $rsync_user:
  ensure     => present,
  gid        => $rsync_user,
  system     => true,
  managehome => true,
}

group { $rsync_user:
  ensure => present,
  system => true,
}

$rsync_user_ssh = merge(
  hiera('rsync_user_ssh_authorized_key', undef),
  {
    ensure  => present,
    user    => $rsync_user,
    options => 'command="${HOME}/.ssh/rsync_only.sh"',
  }
)

ensure_resource(
  'ssh_authorized_key', "${rsync_user}@${rsync_user}", $rsync_user_ssh
)

$ssh_rsync_only = '#!/bin/bash

if [[ "$SSH_ORIGINAL_COMMAND" == rsync\ --server* ]]; then
    $SSH_ORIGINAL_COMMAND
else
    echo "rejected"
fi
'

file { 'rsync_only.sh':
  ensure  => file,
  path    => "/home/${rsync_user}/.ssh/rsync_only.sh",
  mode    => '0755',
  content => $ssh_rsync_only,
  # relying on the ssh_authorized_key resource to create $HOME/.ssh
  require => Ssh_authorized_key['eupspkg@eupspkg'],
}
