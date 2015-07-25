# class: base
class base {
    include base::packages
    include base::monitoring
    include base::ufw
    include ssh
    include users

    cron { 'puppet-run-no-force':
        command => "/root/puppet-run",
        user    => 'root',
        minute  => [ 10, 20, 30, 40, 50 ],
    }

    cron { 'puppet-run-force':
        command => "/root/puppet-run -f",
        user    => 'root',
        hour    => '*',
        minute  => '0',
    }

    file { '/root/puppet-run':
        ensure => present,
        source => 'puppet:///modules/base/puppet/puppet-run',
        mode   => '0775',
    }

    file { '/etc/puppet/puppet.conf':
        ensure => present,
        source => 'puppet:///modules/base/puppet/puppet.conf',
        mode   => '0444',
    }

    file { '/etc/puppet/fileserver.conf':
        ensure => present,
        source => 'puppet:///modules/base/puppet/fileserver.conf',
        mode   => '0444',
    }

    if $::hostname != "misc1" {
        mailalias { 'root':
            recipient => 'root@miraheze.org',
        }
    }
}
