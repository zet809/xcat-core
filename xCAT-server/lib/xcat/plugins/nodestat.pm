package xCAT_plugin::nodestat;
use strict;
use warnings;

use Socket;
use IO::Handle;
use Getopt::Long;
my $stat;

sub handled_commands {
   return { 
      nodestat => 'nodestat',
   };
}

sub pinghost {
   my $node = shift;
   my $rc = system("ping -q -n -c 1 -w 1 $node > /dev/null");
   if ($rc == 0) {
      return 1;
   } else {
      return 0;
   }
}

sub nodesockopen {
   my $node = shift;
   my $port = shift;
   my $socket;
   my $addr = gethostbyname($node);
   my $sin = sockaddr_in($port,$addr);
   my $proto = getprotobyname('tcp');
   socket($socket,PF_INET,SOCK_STREAM,$proto) || return 0;
   connect($socket,$sin) || return 0;
   return 1;
}

sub installer_query {
   my $node = shift;
   my $destport = 3001;
   my $socket;
   my $text = "";
   my $proto = getprotobyname('tcp');
   socket($socket,PF_INET,SOCK_STREAM,$proto) || return 0;
   my $addr = gethostbyname($node);
   my $sin = sockaddr_in($destport,$addr);
   connect($socket,$sin) || return 0;
   print $socket "stat \n";
   $socket->flush;
   while (<$socket>) { 
      $text.=$_;
   }
   $text =~ s/\n.*//;
   return $text;
   close($socket);
}


sub getstat {
   my $response = shift;
   $stat = $response->{node}->[0]->{data}->[0];
}

#-------------------------------------------------------

=head3  preprocess_request

  Check and setup for hierarchy 

=cut

#-------------------------------------------------------
sub preprocess_request
{
    my $req = shift;
    my $cb  = shift;
    my %sn;
    if ($req->{_xcatdest}) { return [$req]; }    #exit if preprocessed
    my $nodes    = $req->{node};
    my $service  = "xcat";
    my @requests;
    if ($nodes){  
      # find service nodes for requested nodes
      # build an individual request for each service node
      my $sn = xCAT::Utils->get_ServiceNode($nodes, $service, "MN");

      # build each request for each service node
      foreach my $snkey (keys %$sn)
      {
            my $reqcopy = {%$req};
            $reqcopy->{node} = $sn->{$snkey};
            $reqcopy->{'_xcatdest'} = $snkey;
            push @requests, $reqcopy;

      }
    }
    else
    {    # non node options like -h 
         @ARGV=();
         my $args=$req->{arg};  
         if ($args) {
           @ARGV = @{$args};
         } else {
            &usage($cb);
            return(1);
         }
         # parse the options
          Getopt::Long::Configure("posix_default");
          Getopt::Long::Configure("no_gnu_compat");
          Getopt::Long::Configure("bundling");
         if (!GetOptions(
          'h|help'     => \$::HELP,
          'v|version'  => \$::VERSION))
         {
              &usage($cb);
              return(1);
         }
         if ($::HELP) {
              &usage($cb);
              return(0);
         } 
         if ($::VERSION) {
             my $version = xCAT::Utils->Version();
             my $rsp={};
             $rsp->{data}->[0] = "$version";
             xCAT::MsgUtils->message("I", $rsp, $cb);
             return(0);
         } 
    }
    return \@requests;
}

sub interrogate_node { #Meant to run against confirmed up nodes
    my $node=shift;
    my $doreq=shift;
    my $status = "";
    if (nodesockopen($node,15002)) {
        $status.="pbs,"
    }
    if (nodesockopen($node,8002)) {
        $status.="xend,"
    }
    if (nodesockopen($node,22)) {
        $status.="sshd,"
    }
    $status =~ s/,$//;
    if ($status) {
        return $status;
    }
    if ($status = installer_query($node)) {
        return  $status;
    } else { #pingable, but no *clue* as to what the state may be
         $doreq->({command=>['nodeset'],
                  node=>[$node],
                  arg=>['stat']},
                  \&getstat);
         return 'ping '.$stat;
     }
}

sub process_request_nmap {
   my $request = shift;
   my $callback = shift;
   my $doreq = shift;
   my %portservices = (
        '22' => 'sshd',
        '15002' => 'pbs',
        '8002' => 'xend',
   );
   my @livenodes;
   my @nodes = @{$request->{node}};
   my %unknownnodes;
   foreach (@nodes) {
	$unknownnodes{$_}=1;
	my $packed_ip = undef;
        $packed_ip = gethostbyname($_);
        if( !defined $packed_ip) {
                my %rsp;
                $rsp{name}=[$_];
                $rsp{data} = [ "Please make sure $_ exists in /etc/hosts or DNS" ];
                $callback->({node=>[\%rsp]});
        }
   }

   my $node;
   my $fping;
   my $ports = join ',',keys %portservices;
   my %deadnodes;
   foreach (@nodes) {
       $deadnodes{$_}=1;
   }
   open($fping,"nmap -p $ports,3001 ".join(' ',@nodes). " 2> /dev/null|") or die("Can't start nmap: $!");
   my $currnode='';
   my $port;
   my $state;
   my %states;
   my %rsp;
   my $installquerypossible=0;
   while (<$fping>) {
      if (/Interesting ports on ([^ ]*) /) {
          $currnode=$1;
          $installquerypossible=0; #reset possibility indicator
          unless ($deadnodes{$1}) {
              foreach (keys %deadnodes) {
                  if ($currnode =~ /^$_\./) {
                      $currnode = $_;
                      last;
                  }
              }
          }
          delete $deadnodes{$currnode};
      } elsif ($currnode) {
          if (/^MAC/) {
              $rsp{name}=[$currnode];
              my $status = join ',',sort keys %states ;
              unless ($status or ($installquerypossible and $status = installer_query($currnode))) { #pingable, but no *clue* as to what the state may be
                 $doreq->({command=>['nodeset'],
                      node=>[$currnode],
                      arg=>['stat']},
                      \&getstat);
                 $status= 'ping '.$stat;
              }

              $rsp{data} = [ $status ];
              $callback->({node=>[\%rsp]});
              $currnode="";
              %states=();
              next;
          }
          if (/^PORT/) { next; }
          ($port,$state) = split;
          if ($port =~ /^(\d*)\// and $state eq 'open') {
              if ($1 eq "3001") {
                $installquerypossible=1; #It is possible to actually query node
              } else {
                $states{$portservices{$1}}=1;
              }
          }
      } 
    }
    foreach $currnode (sort keys %deadnodes) {
         $rsp{name}=[$currnode];
         $rsp{data} = [ 'noping' ];
         $callback->({node=>[\%rsp]});
    }
}

sub process_request {
   if ( -x '/usr/bin/nmap' ) {
       return process_request_nmap(@_);
   }
   my $request = shift;
   my $callback = shift;
   my $doreq = shift;

   my @nodes = @{$request->{node}};
   my %unknownnodes;
   foreach (@nodes) {
	$unknownnodes{$_}=1;
	my $packed_ip = undef;
        $packed_ip = gethostbyname($_);
        if( !defined $packed_ip) {
                my %rsp;
                $rsp{name}=[$_];
                $rsp{data} = [ "Please make sure $_ exists in /etc/hosts" ];
                $callback->({node=>[\%rsp]});
        }
   }

   my $node;
   my $fping;
   open($fping,"fping ".join(' ',@nodes). " 2> /dev/null|") or die("Can't start fping: $!");
   while (<$fping>) {
      my %rsp;
      my $node=$_;
      $node =~ s/ .*//;
      chomp $node;
       if (/ is alive/) {
           $rsp{name}=[$node];
           $rsp{data} = [ interrogate_node($node,$doreq) ];
           $callback->({node=>[\%rsp]});
       } elsif (/is unreachable/) {
         $rsp{name}=[$node];
         $rsp{data} = [ 'noping' ];
         $callback->({node=>[\%rsp]});
       } elsif (/ address not found/) {
         $rsp{name}=[$node];
         $rsp{data} = [ 'nosuchhost' ];
         $callback->({node=>[\%rsp]});
       }
    }
    @nodes=();
   foreach $node (@nodes) {
      my %rsp;
      my $text="";
      $rsp{name}=[$node];
      unless (pinghost($node)) {
         $rsp{data} = [ 'noping' ];
         $callback->({node=>[\%rsp]});
         next;
      }
      if (nodesockopen($node,15002)) {
         $rsp{data} = [ 'pbs' ];
         $callback->({node=>[\%rsp]});
         next;
      } elsif (nodesockopen($node,8002)) {
         $rsp{data} = [ 'xend' ];
         $callback->({node=>[\%rsp]});
         next;
      } elsif (nodesockopen($node,22)) {
         $rsp{data} = [ 'sshd' ];
         $callback->({node=>[\%rsp]});
         next;
      } elsif ($text = installer_query($node)) {
         $rsp{data} = [ $text ];
         $callback->({node=>[\%rsp]});
         next;
      } else {
         $doreq->({command=>['nodeset'],
                  node=>[$node],
                  arg=>['stat']},
                  \&getstat);
         $rsp{data} = [ 'ping '.$stat ];
         $callback->({node=>[\%rsp]});
         next;
      }
   }
}
sub usage
{
    my $cb=shift;
    my $rsp={};
    $rsp->{data}->[0]= "Usage:";
    $rsp->{data}->[1]= "  nodestat [noderange]";
    $rsp->{data}->[2]= "  nodestat [-h|--help|-v|--version]";
    xCAT::MsgUtils->message("I", $rsp, $cb);
}

1;
