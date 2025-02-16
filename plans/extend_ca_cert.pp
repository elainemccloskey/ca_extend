# @summary
#   Plan that extends the Puppet CA certificate and configures the primary Puppet server
#   and Compilers to use the extended certificate.
# @param targets The target node on which to run the plan.  Should be the primary Puppet server
# @param compilers Optional comma separated list of compilers to upload the certificate to
# @param ssldir Location of the ssldir on disk
# @param regen_primary_cert Whether to also regenerate the agent certificate of the primary Puppet server
# @example Extend the CA cert and regenerate the primary agent cert locally on the primary Puppet server
#   bolt plan run ca_extend::extend_ca_cert regen_primary_cert=true --targets local://$(hostname -f) --run-as root
# @example Extend the CA cert by running the plan remotely
#   bolt plan run ca_extend::extend_ca_cert --targets <primary_fqdn> --run-as root
plan ca_extend::extend_ca_cert(
  TargetSpec $targets,
  Optional[TargetSpec] $compilers = undef,
  $ssldir                               = '/etc/puppetlabs/puppet/ssl',
  $regen_primary_cert                   = false,
) {
  $targets.apply_prep
  $primary_facts = run_task('facts', $targets, '_catch_errors' => true).first

  if $primary_facts['pe_build'] {
    $is_pe = true
    $services = ['puppet', 'pe-puppetserver', 'pe-postgresql']
  }
  elsif $primary_facts['puppetversion'] {
    $is_pe = false
    $services = ['puppet', 'puppetserver']
  }
  else {
    fail_plan("Puppet not detected on ${targets}")
  }

  if $is_pe and ! $regen_primary_cert {
    $out = run_task('ca_extend::check_primary_cert', $targets, '_catch_errors' => true).first
    unless $out.ok {
      fail_plan($out.value['message'])
    }
    if $out.value['status'] == 'warn' {
      warning($out.value['message'])
    }
  }

  if $is_pe {
    $crl_results = run_task('ca_extend::check_crl_cert', $targets).first
    if $crl_results['status'] == 'expired' {
      out::message('INFO: CRL expired, truncating to regenerate')
      run_task('ca_extend::crl_truncate', $targets)
    }
  }

  out::message("INFO: Stopping Puppet services on ${targets}")
  $services.each |$service| {
    run_task('service::linux', $targets, 'action' => 'stop', 'name' => $service)
  }

  out::message("INFO: Extending CA certificate on ${targets}")
  $regen_results = run_task('ca_extend::extend_ca_cert', $targets)
  $new_cert = $regen_results.first.value
  $cert_contents = base64('decode', $new_cert['contents'])

  out::message("INFO: Configuring ${targets} to use the extended CA certificate")
  if $is_pe {
    run_task('ca_extend::configure_primary', $targets,
      'new_cert' => $new_cert['new_cert'], 'regen_primary_cert' => $regen_primary_cert
    )
  }
  else {
    run_command("/bin/cp ${new_cert['new_cert']} ${ssldir}/certs/ca.pem", $targets)
    run_command("/bin/cp ${new_cert['new_cert']} ${ssldir}/ca/ca_crt.pem", $targets)
    run_task('service::linux', $targets, 'action' => 'start', 'name' => 'puppetserver')
  }
  run_task('service::linux', $targets, 'action' => 'start', 'name' => 'puppet')

  $tmp = run_command('mktemp', 'localhost', '_run_as' => system::env('USER'))
  $tmp_file = $tmp.first.value['stdout'].chomp
  file::write($tmp_file, $cert_contents)

  if $compilers {
    out::message("INFO: Stopping Puppet services on compilers (${compilers})")
    run_task('service::linux', $compilers, 'action' => 'stop', 'name' => 'puppet')

    out::message("INFO: Configuring compilers (${compilers}) to use the extended CA certificate")
    upload_file($tmp_file, '/etc/puppetlabs/puppet/ssl/certs/ca.pem', $compilers)

    # Just running Puppet with the new CA certificate in place should be enough.
    run_command('/opt/puppetlabs/bin/puppet agent --no-daemonize --no-noop --onetime', $compilers)
    run_task('service::linux', $compilers, 'action' => 'start', 'name' => 'puppet')
  }

  out::message("INFO: Extended CA certificate decoded and stored at ${tmp_file}")
  out::message("INFO: Run the 'ca_extend::upload_ca_cert' plan to distribute the extended CA certificate to agents")
}
