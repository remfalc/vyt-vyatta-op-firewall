#!/usr/bin/perl

use lib "/opt/vyatta/share/perl5/";
use VyattaConfig;
use VyattaIpTablesRule;
use VyattaIpTablesAddressFilter;

exit 1 if ($#ARGV < 1);
my $chain_name = $ARGV[0];
my $xsl_file = $ARGV[1];
my $rule_num = $ARGV[2];    # rule number to match (optional)

if (! -e $xsl_file) {
  print "Invalid XSL file \"$xsl_file\"\n";
  exit 1;
}

if (defined($rule_num) && (!($rule_num =~ /^\d+$/) || ($rule_num > 1025))) {
  print "Invalid rule number \"$rule_num\"\n";
  exit 1;
}

sub numerically { $a <=> $b; }

### all interfaces firewall nodes
#/ethernet/node.tag/pppoe/node.tag/firewall/<dir>/name/node.def
#/ethernet/node.tag/vif/node.tag/firewall/<dir>/name/node.def
#/ethernet/node.tag/firewall/<dir>/name/node.def
#/adsl/node.tag/pvc/node.tag/pppoa/node.tag/firewall/<dir>/name/node.def
#/adsl/node.tag/pvc/node.tag/pppoe/node.tag/firewall/<dir>/name/node.def
#/adsl/node.tag/pvc/node.tag/classical-ipoa/firewall/<dir>/name/node.def
#/tunnel/node.tag/firewall/<dir>/name/node.def
#/serial/node.tag/cisco-hdlc/vif/node.tag/firewall/<dir>/name/node.def
#/serial/node.tag/frame-relay/vif/node.tag/firewall/<dir>/name/node.def
#/serial/node.tag/ppp/vif/node.tag/firewall/<dir>/name/node.def

sub show_interfaces {
  my $chain = shift;
  my $cmd = "find /opt/vyatta/config/active/ "
            . "|grep -e '/firewall/[^/]\\+/name/node.val'"
            . "| xargs grep -l '^$chain\$'";
  my $ifd;
  return if (!open($ifd, "$cmd |"));
  my @ints = <$ifd>;
  # e.g.,
  #/opt/vyatta/config/active/interfaces/ethernet/eth1/firewall/in/name/node.val
  my $pfx = '/opt/vyatta/config/active/interfaces';
  my $sfx = '/name/node.val';
  my @int_strs = ();
  foreach (@ints) {
    my ($intf, $vif, $dir) = (undef, undef, undef);
    if (/^$pfx\/[^\/]+\/([^\/]+)(\/.*)?\/firewall\/([^\/]+)$sfx$/) {
      ($intf, $dir) = ($1, $3);
      $dir =~ y/a-z/A-Z/;
    } else {
      next;
    }
    if (/\/vif\/([^\/]+)\/firewall\//) {
      $vif = $1;
      push @int_strs, "($intf.$vif,$dir)";
    } else {
      push @int_strs, "($intf,$dir)";
    }
  }
  if (scalar(@int_strs) > 0) {
    print "\nActive on " . (join ' ', @int_strs) . "\n";
  }
}

sub show_chain {
  my $chain = shift;
  my $fh = shift;

  open my $iptables, "-|"
      or exec "sudo", "/sbin/iptables", "-L", $chain, "-vn"
      or exit 1;
  my @stats = ();
  while (<$iptables>) {
    if (!/^\s*(\d+[KMG]?)\s+(\d+[KMG]?)\s/) {
      next;
    }
    push @stats, ($1, $2);
  }
  close $iptables;

  print $fh "<opcommand name='firewallrules'><format type='row'>\n";
  my $config = new VyattaConfig;
  $config->setLevel("firewall name $chain rule");
  my @rules = sort numerically $config->listOrigNodes();
  foreach (@rules) {
    # just take the stats from the 1st iptables rule and remove unneeded stats
    # (if this rule corresponds to multiple iptables rules). note that
    # depending on how our rule is translated into multiple iptables rules,
    # this may actually need to be the sum of all corresponding iptables stats
    # instead of just taking the first pair.
    my $pkts = shift @stats;
    my $bytes = shift @stats;
    my $rule = new VyattaIpTablesRule;
    $rule->setupOrig("firewall name $chain rule $_");
    my $ipt_rules = $rule->get_num_ipt_rules();
    splice(@stats, 0, (($ipt_rules - 1) * 2));

    if (defined($rule_num) && $rule_num != $_) {
      next;
    }
    print $fh "  <row>\n";
    print $fh "    <rule_number>$_</rule_number>\n";
    print $fh "    <pkts>$pkts</pkts>\n";
    print $fh "    <bytes>$bytes</bytes>\n";
    $rule->outputXml($fh);
    print $fh "  </row>\n";
  }
  if (!defined($rule_num)) {
    # dummy rule
    print $fh "  <row>\n";
    print $fh "    <rule_number>1025</rule_number>\n";
    my $pkts = shift @stats;
    my $bytes = shift @stats;
    print $fh "    <pkts>$pkts</pkts>\n";
    print $fh "    <bytes>$bytes</bytes>\n";
    my $rule = new VyattaIpTablesRule;
    $rule->setupDummy();
    $rule->outputXml($fh);
    print $fh "  </row>\n";
  }
  print $fh "</format></opcommand>\n";
}

my $config = new VyattaConfig;
$config->setLevel("firewall name");
my @chains = $config->listOrigNodes();
if ($chain_name eq "-all") {
  foreach (@chains) {
    print "Firewall \"$_\":\n";
    show_interfaces($_);
    open(RENDER, "| /opt/vyatta/sbin/render_xml $xsl_file") or exit 1;
    show_chain($_, *RENDER{IO});
    close RENDER;
    print "-" x 80 . "\n";
  }
} else {
  if (scalar(grep(/^$chain_name$/, @chains)) <= 0) {
    print "Invalid name \"$chain_name\"\n";
    exit 1;
  }
  show_interfaces($chain_name);
  open(RENDER, "| /opt/vyatta/sbin/render_xml $xsl_file") or exit 1;
  show_chain($chain_name, *RENDER{IO});
  close RENDER;
}

exit 0;

