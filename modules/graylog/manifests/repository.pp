class graylog::repository (
  $version = $graylog::params::major_version,
  $url     = undef,
  $proxy = undef,
  $release = $graylog::params::repository_release,
) inherits graylog::params {
  anchor { 'graylog::repository::begin': }

  if $url == undef {
    $graylog_repo_url = $facts['os']['family'] ? {
      'debian' => 'https://downloads.graylog.org/repo/debian/',
      'redhat' => "https://downloads.graylog.org/repo/el/${release}/${version}/\$basearch/",
      default  => fail("${facts['os']['family']} is not supported!"),
      }
  } else {
    $graylog_repo_url = $url
  }

  case $facts['os']['family'] {
    'debian': {
      class { 'graylog::repository::apt':
        url     => $graylog_repo_url,
        release => $release,
        version => $version,
        proxy   => $proxy,
      }
    }
    'redhat': {
      class { 'graylog::repository::yum':
        url   => $graylog_repo_url,
        proxy => $proxy,
      }
    }
    default: {
      fail("${facts['os']['family']} is not supported!")
    }
  }
  anchor { 'graylog::repository::end': }
}
