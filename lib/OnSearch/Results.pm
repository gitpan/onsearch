package OnSearch::Results; 

=head1 NAME

OnSearch::Results - Collect and display results of searches.

=head1 DESCRIPTION

OnSearch::Results collects the results of searches generated by
L<OnSearch::Search(3)>, saves the results to disk if necessary, queues
the results for display, and displays the first page of results.

The application calls the subroutine, results (), which then collects
results until the L<OnSearch::Search(3)> signals that it has completed a 
search.

=cut

#$Id: Results.pm,v 1.26 2005/08/22 13:45:51 kiesling Exp $

my ($VERSION)= ('$Revision: 1.26 $' =~ /:\s+(.*)\s+\$/);

use strict;
use warnings;
use POSIX qw(:fcntl_h);
use Socket;
use Storable qw/store_fd/;

use OnSearch;
use OnSearch::Regex;
use OnSearch::VFile;
use OnSearch::StringSearch;
use OnSearch::Utils;
use OnSearch::URL;
use OnSearch::WebLog;

require Exporter;
require DynaLoader;
my (@ISA);
@ISA = qw(Exporter DynaLoader);

my $logfunc = \&OnSearch::WebLog::clf;

sub results {
    my $ui_obj = shift;
    my $ppid = $_[0];
    my $q = $ui_obj -> {q};

    ###
    ### Save the process id as a query parameter.
    ###
    $ui_obj -> {id} = $q -> {id} = $ppid;

    my ($chldpid, $resultspid, $rid, $r);

  FORK:
    if ($chldpid = fork ()) {
	return $chldpid;
    } elsif (defined $chldpid) {
	setpgrp (0,0);
      FORK2:
	if ($rid = fork ()) {
	    return $rid;
	} elsif (defined $rid) {
	    ###
	    ###  See the comments in WebClient.pm.
	    ###
	    chdir '/' || die "OnSearch: Could not chdir /: $!\n";
	    close STDIN;
	    ###
	    ### STDOUT gets closed after the displaying the
	    ### first page of results.
	    ###
	    close STDERR;

	    &$logfunc ('notice', "Results started PID $$, ID $ppid.");
	    $r = $ui_obj -> OnSearch::Results::collect_results 
		($ppid, $resultspid);

	    ###
	    ### The program needs to check here if there's 
	    ### only a partial page of results... the first 
	    ### of more than one page of results is output 
	    ### below.  Then output the page footer.
	    ###
	    unless ($ui_obj -> {firstpagedisplayed}) {
		while ($ui_obj -> {head} <= $#{$ui_obj -> {r}}) {
		    display_result ($ui_obj);
		    ++$ui_obj -> {head};
		}
		$ui_obj -> {pageno} = 1;
		$ui_obj -> results_footer -> wprint;
		$ui_obj -> html_footer -> wprint;
	    }

	    ### Return from the grandchild process with exit code
            ### so the calling script can exit.
	    return 0;
	} elsif ($! =~ /No more processes|Resource temporarily unavailable/) {
	    &$logfunc ('warning', "Results () unable to fork: $! PID $$.");
	    sleep 2;
	    redo FORK2;
	} else {
	    die "results () error PID $chldpid: $!";
	}
    } elsif ($! =~ /No more processes|Resource temporarily unavailable/) {
	&$logfunc ('warning', "Results () unable to fork: $! PID $$.");
	sleep 2;
	redo FORK;
    } else {
	die "results () error PID $chldpid: $!";
    }

    ### Return code from child process so the calling script can
    ### exit.
    return 0;
}

###
### In order to hold connection with the client open during long 
### searches, collect_results () sends a space character to the 
### client periodically.  Collect_results () sets SIGALRM to expire 
### after 30 seconds, then client_ping () sends a space character
### and resets the SIGALRM handler.  The collector stops holding 
### the connection open (by setting SIGALRM to 0) after it displays 
### the first page of results.
###
sub client_ping {
    my $u = OnSearch::UI->new;
    $u -> {text} = ' ';
    $u -> wprint;
    undef $u;  # Quicker than garbage collection.
    alarm 30;
    $SIG{ALRM} = \&client_ping;
}

my $searchstr = \&OnSearch::StringSearch::_strindex;

###
### Collect_results () displays only the first $PageSize of
### matched documents but reads data sent by Search.pm until 
### it receives a </results> tag.  
###
sub collect_results {
    my $ui_obj = shift;
    my $ppid = $_[0];
    my $resultspid = $_[1];


    my ($l, $rec, $r, $q, $buf, @lines, $linebuf);
    $q = $ui_obj -> {q};
    $ui_obj -> {firstpagedisplayed} = 0;

    # Expire cookie in a year.
    my $yearexpdate = OnSearch::Utils::http_date (31536000);
    $ui_obj -> header_cookie ('OnSearch', 'onsearchprefs', 
			  OnSearch::AppConfig->prefs_val ($ui_obj -> {q}),
			  $yearexpdate) 
	-> wprint;

    local $SIG{ALRM} = \&client_ping;
    alarm 30;

    ###
    ### Try to save the results before exiting if the Web server sends 
    ### a SIGINT.
    ###
    local $SIG{INT} = sub {
	if (! ($r = store_result ($ui_obj))) {
	    warn ('error', 
		  "collect_results: SIGINT. Couldn't save session $ppid: $!");
	}
	exit 1;
    };

    ###
    ### The comments in results.cgi describe the result queue 
    ### indexes.
    ###
    $ui_obj -> {head} = 0;
    $ui_obj -> {pagenth} = 0;
    $ui_obj -> {pageno} = 1;
    display_header ($ui_obj);

    while (1) {
	$linebuf = _receive ($ppid);
	next unless $linebuf && length ($linebuf);

	if (defined (&$searchstr ('</results>', $linebuf))) {
	    $ui_obj -> {completed} = 1;
	    $r = store_result ($ui_obj);
	    return 0;
	}

	@lines = split /\n/, $linebuf;

####
#### FIXME - This should not occur.
####
	next if $#lines <= 1;  # Empty record.

	###
	### Create a new array for each record.
	###
	$rec = _new_array_ref ();
	push @{$rec}, @lines;

	push @{$ui_obj -> {r}}, ($rec);

	###
	### Note here if the first page has been 
	### displayed. This saves a lot of effort when 
	### trying to display pages from results.cgi.
	###
	unless ($ui_obj -> {firstpagedisplayed}) {
	    display_result ($ui_obj);
	    $ui_obj -> {head} += 1;
	    if ($ui_obj -> {head} >= $ui_obj -> {pagesize}) {
		### Discontinue pinging the client.
		alarm 0;
		###
		### Waiting here simplifies the code in 
		### results_footer ().  Although the wait 
		### can cause a slight delay initially, 
		### it tends to speed up the page display
		### later on.
		###
		$ui_obj -> results_footer -> wprint;
		$ui_obj -> html_footer -> wprint;
		$ui_obj -> {firstpagedisplayed} = 1;
		###
		### Now we can shut down the output's STDOUT.
		###
		close STDOUT;
	    }
	    $r = store_result ($ui_obj);
	}
	###
	### Save every $PageSize results after displaying
	### the first page.  Save also if the server tries 
	### to terminate the script by sending a SIGINT, and 
	### after receiving a </results> tag.
	###
	$r = store_result ($ui_obj)
	    if ($#{$ui_obj->{r}} % $ui_obj -> {pagesize} == 0);
    }
    return;
}

sub _receive {
    my $session_id = shift;
    my ($name, $datafh, $r, $l);
    $name = "/tmp/.onsearch.sock.$session_id";
    #
    # Wait on the socket.
    #
    while (! -S $name) { }
    socket ($datafh, PF_UNIX, SOCK_STREAM, 0)  or do {
	&$logfunc ('error', "_receive: $!");
    };
    #
    # Then wait until the socket is listening.
    #
    while (1) {
	$r = connect ($datafh, sockaddr_un ($name));
	if ((! $r) && $! && ($! !~ /Connection refused/)) {
	    &$logfunc ('warning', "_receive PID $$: $!");
	} elsif ($r) {
	    read ($datafh, $l, 0xFFFF);
	    last;
	}
    }
    close $datafh;
    return $l;
}

sub _new_array_ref { my @a; return \@a; }

my $PATHTAG = qr'<file path="(.*)">';
my $WORDTAG = qr'\s*<word chars="(.*)">(.*)</word>';

sub read_postings {
    my $q = $_[0];
    my $rec = $_[1];

    my (@offsets, @soffsets, $w, $o);
    my ($vf, $r, $os, $path);
    my ($inbuf, @results);
    my ($displayed_start, $displayed_end);

    ($path) = ($rec->[0] =~ $PATHTAG);
    push @results, ($path);

    undef $o;
    for (my $i = 1; $i < $#{$rec}; $i++) {
	($w, $o) = ($rec -> [$i] =~ $WORDTAG);
	push @offsets, (split /,/, $o) if $o;
	undef $o;
    }
    
    ###
    ### Sorting here means that we only need to 
    ### keep track of the offsets of the previous
    ### line displayed, not all of the lines 
    ### displayed.
    ###
    @soffsets = sort {$a <=> $b} @offsets;

    $vf = OnSearch::VFile -> new;

    if (! defined ($r = $vf -> vfopen ($path))) {
	warn ("read_postings vfopen $path: $!");
	$vf -> vfclose ();
	return \@results;
    }

    $displayed_start = $displayed_end = 0xFFFF;
    foreach $os (@soffsets) {
	next if (($os >= $displayed_start) && ($os <= $displayed_end));
	$displayed_start = $q->{context} < $os ? $os - $q->{context} : 0;
	$r = $vf -> vfseek ($displayed_start, 0);
	unless ($r) {
	    warn "Read postings vfseek: $r, $os";
	    return \@results;
	}
	unless (defined ($inbuf = $vf -> vfread ($q -> {context} * 3))) {
	    warn "Read postings vfread: $path, offset $os: $!";
	    return \@results;
	}
	if ($inbuf =~ $q -> {displayregex}) {
	    $displayed_end = $displayed_start + $q -> {context} * 3;
	    push @results, ($inbuf);
	}
    }
    $vf -> vfclose;

    return \@results;
}

sub store_result {
    my $ui_obj = $_[0];

    my $datadir = OnSearch::AppConfig->str ('DataDir');
    my $datafn = $datadir . '/session.' . $ui_obj -> {q} -> {ppid};
    my $lockfn = $datafn . '.lck';
    my ($r, $mode, $datafh, $lockfh);

    ###
    ### We could use flock here, but a lock file is more reliable 
    ### if one or more of the processes respawns.

    ###
    ### If there's already a lock file, wait.
    ###
    while (-f $lockfn) { }
    local $!;
    ###
    ### Suppress standard input and output channel 
    ### warnings.
    ###
    no warnings;
    sysopen ($lockfh, $lockfn, O_WRONLY | O_TRUNC | O_CREAT) || do {
	$ui_obj -> {text} = "Error $lockfn: $!";
	$ui_obj -> wprint;
	warn "store_result open $lockfn: $!";
	return undef;
    };
    use warnings;
    print $lockfh $ui_obj -> {q} -> {ppid};
    close ($lockfh);

    if (-f $datafn) { $mode = O_WRONLY | O_TRUNC; } 
    else { $mode = O_WRONLY | O_CREAT; }
    no warnings;
    sysopen ($datafh, $datafn, $mode) || do {
	$ui_obj -> {text} = "Error $datafn $!";
	$ui_obj -> wprint;
	warn "store_result open $datafn: $!";
	return undef;
      };
    use warnings;
    ###
    ### Storable doesn't handle typeglobs, so save and restore
    ### them.  This so far does not affect output handles in other 
    ### modules.
    ###
    my $tmpfh = $ui_obj -> {outputfh};
    undef $ui_obj -> {outputfh};
    my $tmpsfptr = $ui_obj -> {q} -> {sfptr};
    undef $ui_obj -> {q} -> {sfptr};
    eval { store_fd ($ui_obj, \*$datafh) || do 
	   {
	       warn "store_result $datafn: $!";
	       close ($datafh);
	       return undef;
	   };
       };
    $ui_obj -> {outputfh} = $tmpfh;
    $ui_obj -> {q} -> {sfptr} = $tmpsfptr;
    close ($datafh);
    unlink ($lockfn) || do {
	warn "store_result unlink $lockfn: $!";
	return undef;
    };
	
    return 1;
}

sub display_header {
    my $ui = $_[0];

###
### Send the appropriate HTTP header first.
###
    $ui -> navbar_map -> wprint;
    $ui -> javascripts -> wprint;
    $ui -> navbar -> wprint;
    $ui -> querytitle -> wprint;
    $ui -> results_header -> wprint;
}

###
### The comments in results.cgi describe the queue indexes.
###
sub display_result {
    my $ui_obj = $_[0];

    my ($rlist, $url);
    my $r = undef;

    ###
    ### Don't read past the end of the queue.
    ###
    return $r unless $#{$ui_obj -> {r}} >= $ui_obj -> {head};

    $rlist = 
	read_postings ($ui_obj ->{q}, $ui_obj -> {r} -> [$ui_obj->{head}]);
    
    ###
    ### The first element is the name of the file.
    ###
    if ($#{$rlist} > 0) {
	$url = OnSearch::URL::map_url ($rlist -> [0]);
	$rlist -> [0] = $url if $url;
	$ui_obj -> results_form (collate_results ($rlist, 
		 $ui_obj -> {nresults},
		 $ui_obj -> {q})) 
	    -> wprint; 
	$r = 1;
    }
    return $r;
}

sub collate_results {
    my $rlist = $_[0];
    my $nresults = $_[1];
    my $q = $_[2];

    my ($i, $i_val, $n, %results, $word, $collated_rlist, $regex);

    $regex = $q -> {displayregex};

    foreach $i (@{$rlist}) {
	($word) = ($i =~ m"($regex)");
	next unless $word;
	$results{$word} = _new_array_ref () unless $results{$word};
	push @{$results{$word}}, ($i);
    }
    
    $n = 1;
    $collated_rlist = _new_array_ref;

    ###
    ### Name and path of the document.
    ###
    push @{$collated_rlist}, ($rlist->[0]);

    while (($n <= $nresults) && %results) {
	foreach $i (keys %results) {
	    last if $n > $nresults;
	    if ($#{$results{$i}} >= 0) {
		$i_val = shift @{$results{$i}};
		push @{$collated_rlist}, ($i_val);
		++$n;
	    } else {
		delete $results{$i};
	    }
	}
    }
    return $collated_rlist;
}

__END__

1;

=head1 SEE ALSO

L<OnSearch(3)>

=cut
