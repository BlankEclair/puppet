# class: prometheus
class prometheus (
    Hash $global_extra = {},
    Array $scrape_extra = [],
    Integer $port = 9100
) {

    stdlib::ensure_packages('prometheus')

    file { '/etc/prometheus/targets':
        ensure => directory
    }

    $global_default = {
        'scrape_interval' => '60s',
    }
    $global_config = $global_default + $global_extra

    $scrape_default = [
        {
            'job_name' => 'prometheus',
            'static_configs' => [
                {
                    'targets' => [
                        'localhost:9090'
                    ],
                }
            ]
        },
        {
            'job_name' => 'node',
            'file_sd_configs' => [
                {
                    'files' => [
                        '/etc/prometheus/targets/nodes.yaml'
                    ]
                }
            ]
        }
    ]
    $scrape_config = concat($scrape_default, $scrape_extra)

    $common_config = {
        'global' => $global_config,
        'rule_files' => [],
        'scrape_configs' => $scrape_config
    }

    file { '/etc/prometheus/prometheus.yml':
        content => stdlib::to_yaml($common_config),
        notify  => Exec['prometheus-reload']
    }

    exec { 'prometheus-reload':
        command     => '/bin/systemctl reload prometheus',
        refreshonly => true,
    }

    $servers = query_nodes('Class[Base]')
              .flatten()
              .unique()
              .sort()

    file { '/etc/prometheus/targets/nodes.yaml':
        ensure  => present,
        mode    => '0444',
        content => template('prometheus/nodes.erb')
    }

    systemd::service { 'prometheus':
        ensure         => present,
        restart        => true,
        content        => systemd_template('prometheus'),
        service_params => {
            hasrestart => true,
        },
    }

    class { 'prometheus::pushgateway':
        ensure      => present,
        listen_port => 9091,
    }

    monitoring::services { 'Prometheus':
        check_command => 'tcp',
        vars          => {
            tcp_port    => '9090',
        },
    }
}
