required_plugins = %w{
  vagrant-librarian-puppet
  vagrant-puppet-install
  vagrant-openstack-provider
}

plugins_to_install = required_plugins.select { |plugin| not Vagrant.has_plugin? plugin }
if not plugins_to_install.empty?
  puts "Installing plugins: #{plugins_to_install.join(' ')}"
  system "vagrant plugin install #{plugins_to_install.join(' ')}"
  exec "vagrant #{ARGV.join(' ')}"
end

# generate a psuedo unique hostname to avoid droplet name/aws tag collisions.
# eg, "jhoblitt-sxn-<os>"
# based on:
# https://stackoverflow.com/questions/88311/how-best-to-generate-a-random-string-in-ruby
def gen_hostname(boxname)
  "#{ENV['USER']}-#{(0...3).map { (65 + rand(26)).chr }.join.downcase}-#{boxname}"
end
def ci_hostname(hostname, provider)
  provider.user_data = <<-EOS
#cloud-config
hostname: #{hostname}
manage_etc_hosts: localhost
  EOS
end

Vagrant.configure('2') do |config|
  config.ssh.username = 'vagrant'
  config.vm.boot_timeout = 900

  config.vm.synced_folder ".", "/vagrant", disabled: true

  config.vm.define 'el7' do |define|
    hostname = gen_hostname('el7')
    define.vm.hostname = hostname

    define.vm.provider :virtualbox do |provider, override|
      override.vm.box = 'bento/centos-7.1'
      override.vm.network 'public_network', bridge: 'eno1'
    end

    define.vm.provider :openstack do |provider, override|
      ci_hostname(hostname, provider)
      provider.image = 'ee17a738-a2d5-4cbf-b599-5721b8aa4552'
      provider.server_name = "el7-#{ENV['USER']}"
    end
  end

  # setup the remote repo needed to install a current version of puppet
  config.puppet_install.puppet_version = '3.8.2'

  config.vm.synced_folder 'hieradata/', '/tmp/vagrant-puppet/hieradata'

  config.vm.provision :puppet do |puppet|
    puppet.manifests_path = "manifests"
    puppet.module_path = "modules"
    puppet.manifest_file = "init.pp"
    puppet.hiera_config_path = "hiera.yaml"
    puppet.options = [
     '--verbose',
     '--report',
     '--show_diff',
     '--pluginsync',
     '--disable_warnings=deprecations',
    ]
  end

  config.vm.provider :virtualbox do |provider, override|
    provider.memory = 4096
    provider.cpus = 4
  end

  config.vm.provider :openstack do |os,override|
        override.vm.synced_folder '.', '/vagrant', :disabled => true

#    os.sync_method        = 'none'
    os.user_data          = <<-EOS
#cloud-config
system_info:
  default_user:
    name: vagrant
    EOS
    os.username           = ENV['OS_USERNAME']
    os.password           = ENV['OS_PASSWORD']
    os.tenant_name        = ENV['OS_PROJECT_NAME']
    os.openstack_auth_url = ENV['OS_AUTH_URL']
    os.flavor             = 'm1.xlarge'
    os.floating_ip_pool   = 'ext-net'
    os.security_groups    = ['default', 'remote SSH', 'remote HTTP', 'remote https']
    os.networks           = ['fc77a88d-a9fb-47bb-a65d-39d1be7a7174']
  end

  if Vagrant.has_plugin?('vagrant-librarian-puppet')
    config.librarian_puppet.placeholder_filename = ".gitkeep"
  end

  if Vagrant.has_plugin?("vagrant-cachier")
    config.cache.scope = :box
  end
end
