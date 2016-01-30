include ::stdlib
include ::augeas
include ::sysstat
include ::ntp
include ::irqbalance
include ::epel
include ::nginx

$user  = 'vagrant'
$group = 'vagrant'
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

$eupspkg_host       = hiera('eupspkg_host', 'eupspkg-test')
$eupspkg_access_log = "/var/log/nginx/${eupspkg_host}.access.log"
$eupspkg_error_log  = "/var/log/nginx/${eupspkg_host}.error.log"
$eupspkg_root       = '/opt/lsst/eupspkg'

$doxygen_host       = hiera('doxygen_host', 'doxygen-test')
$doxygen_access_log = "/var/log/nginx/${doxygen_host}.access.log"
$doxygen_error_log  = "/var/log/nginx/${doxygen_host}.error.log"
$doxygen_root       = '/opt/lsst/doxygen'

$conda_host       = hiera('conda_host', 'conda-test')
$conda_access_log = "/var/log/nginx/${conda_host}.access.log"
$conda_error_log  = "/var/log/nginx/${conda_host}.error.log"
$conda_root       = '/opt/lsst/conda'

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
$eupspkg_raw_prepend = [
  "if ( \$host != \'${eupspkg_host}\' ) {",
  "  return 301 https://${eupspkg_host}\$request_uri;",
  '}',
]

$doxygen_raw_prepend = [
  "if ( \$host != \'${doxygen_host}\' ) {",
  "  return 301 https://${doxygen_host}\$request_uri;",
  '}',
]

$conda_raw_prepend = [
  "if ( \$host != \'${conda_host}\' ) {",
  "  return 301 https://${conda_host}\$request_uri;",
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

  nginx::resource::vhost { "${eupspkg_host}-ssl":
    ensure               => present,
    server_name          => [$eupspkg_host],
    listen_port          => 443,
    ssl                  => true,
    rewrite_to_https     => false,
    access_log           => $eupspkg_access_log,
    error_log            => $eupspkg_error_log,
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
    raw_prepend          => $eupspkg_raw_prepend,
    use_default_location => false,
    index_files          => [],
    www_root             => $eupspkg_root,
  }

  nginx::resource::upstream { 'apache-eupspkg':
    ensure  => present,
    members => [
      '127.0.0.1:8080',
    ],
  }

  # eups distrib parses the apache directory index HTML format so we are
  # proxying from nginx -> apache to provide the expected format
  # NOTE that apache directory listing refers to images under /icons
  nginx::resource::location { "${name}-eupspkg":
    ensure                => present,
    vhost                 => "${eupspkg_host}-ssl",
    ssl                   => true, # only needed for ordering in vhost file
    ssl_only              => true,
    #location              => '/eupspkg', # no trailing slash for auto redirect
    location              => '/',
    proxy                 => 'http://apache-eupspkg',
    proxy_redirect        => 'default',
    proxy_connect_timeout => '30',
    rewrite_rules         => [
      # strip base path from old sw.lsstcorp.org/eupspkg/ urls that have been
      # redriected
      "^/eupspkg(.*)\$ https://${eupspkg_host}\$1 permanent",
    ]
  }

  # doxygen
  nginx::resource::vhost { "${doxygen_host}-ssl":
    ensure               => present,
    server_name          => [$doxygen_host],
    listen_port          => 443,
    ssl                  => true,
    rewrite_to_https     => false,
    access_log           => $doxygen_access_log,
    error_log            => $doxygen_error_log,
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
    raw_prepend          => $doxygen_raw_prepend,
    autoindex            => 'on',
    use_default_location => true,
    index_files          => [],
    www_root             => $doxygen_root,
  }

  # conda
  nginx::resource::vhost { "${conda_host}-ssl":
    ensure               => present,
    server_name          => [$conda_host],
    listen_port          => 443,
    ssl                  => true,
    rewrite_to_https     => false,
    access_log           => $conda_access_log,
    error_log            => $conda_error_log,
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
    raw_prepend          => $conda_raw_prepend,
    autoindex            => 'on',
    use_default_location => true,
    index_files          => [],
    www_root             => $conda_root,
  }
}

nginx::resource::vhost { $eupspkg_host:
  ensure               => present,
  server_name          => [
    $eupspkg_host,
    'sw.lsstcorp.org',
  ],
  listen_port          => 80,
  ssl                  => false,
  access_log           => $eupspkg_access_log,
  error_log            => $eupspkg_error_log,
  rewrite_to_https     => false,
  use_default_location => false,
  index_files          => [],
  # see comment above $raw_prepend declaration
  raw_prepend          => $enable_ssl ? {
    true    => [
      "return 301 https://${eupspkg_host}\$request_uri;",
    ],
    default => undef,
  },
}

nginx::resource::vhost { $doxygen_host:
  ensure               => present,
  listen_port          => 80,
  ssl                  => false,
  access_log           => $doxygen_access_log,
  error_log            => $doxygen_error_log,
  rewrite_to_https     => false,
  use_default_location => false,
  index_files          => [],
  # see comment above $raw_prepend declaration
  raw_prepend          => $enable_ssl ? {
    true    => [
      "return 301 https://${doxygen_host}\$request_uri;",
    ],
    default => undef,
  },
}

# conda
nginx::resource::vhost { $conda_host:
  ensure               => present,
  listen_port          => 80,
  ssl                  => false,
  access_log           => $conda_access_log,
  error_log            => $conda_error_log,
  rewrite_to_https     => false,
  use_default_location => false,
  index_files          => [],
  # see comment above $raw_prepend declaration
  raw_prepend          => $enable_ssl ? {
    true    => [
      "return 301 https://${conda_host}\$request_uri;",
    ],
    default => undef,
  },
}

class { 'apache':
  default_vhost => false,
}

apache::vhost { $eupspkg_host:
  ip      => '127.0.0.1',
  port    => '8080',
  docroot => $eupspkg_root,
  aliases => [
    {
      aliasmatch => '^/eupspkg(.*)$',
      path       => "${eupspkg_root}/\$1",
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
  $eupspkg_root,
  $doxygen_root,
  $conda_root,
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
