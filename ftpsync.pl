#!/usr/bin/perl

# This script is (c) 2002 Luis E. Muñoz, All Rights Reserved
#                (c) 2005 Peter Orvos, All Rights Reserved
#                (c) 2006 Edwin Zuidema, All Rights Reserved
#		 (c) 2008 Plato, All Rights Reserved
# This code can be used under the same terms as Perl itself. It comes
# with absolutely NO WARRANTY. Use at your own risk.
#
# TO BE DONE
# - mtime: if from L->R, R has current mtime. Then next round R will go L (newer)
#   And then L-R and so on. How to solve? Remote mtime? update local time?
#

use strict;
use warnings;
use Net::FTP;
use File::Find;
use File::Listing; # Try EZ
use Pod::Usage;
use Getopt::Std;
use POSIX 'strftime';
#Plato Wu,2008/09/06
use Storable;
use Digest::MD5;
# Plato Wu,2008/12/03
use File::stat;

use vars qw($opt_s $opt_k $opt_u $opt_l $opt_p $opt_r $opt_h $opt_v
            $opt_d $opt_P $opt_i $opt_o);

getopts('i:o:l:s:u:p:r:hkvdP');

if ($opt_h)
{
    pod2usage({-exitval => 2,
               -verbose => 2});
}
                                # Defaults are set here
$opt_s ||= 'localhost';
$opt_u ||= 'anonymous';
$opt_p ||= 'someuser@';
$opt_r ||= '/';
$opt_l ||= '.';
$opt_o ||= 0;

$opt_i = qr/$opt_i/ if $opt_i;

$|++;                           # Autoflush STDIN

# Plato Wu,2008/12/11: use opt_k for first loop and not for second loop.
$opt_k = 1;			
kidorreally:

my %rem = ();
my %loc = ();

my $last_file = ".last";

print "Using time offset of $opt_o seconds\n" if $opt_v and $opt_o;

                                # Phase 0: Scan local path and see what we
                                # have
print "\n### Phase 0: Scanning local ###\n" if $opt_v; 

print "dir: $opt_l\n" if $opt_v;
chdir $opt_l or die "Cannot change dir to $opt_l: $!\n";

# First get date/time of last sync
# Plato Wu,2008/12/03 stat()[9] is NG, use stat()->mtime instead.
my $last = -e $last_file ? (stat($last_file))->mtime : 0;
#my $last = ((stat($last_file))[9] || 0);
my $mdtm_form = strftime("%c",localtime($last));
print "Last time synced: $mdtm_form\n" if $opt_k;

find(
     {
         no_chdir       => 1,
         follow         => 0,   # No symlinks, please
         wanted         => sub
         {
             return if $File::Find::name eq '.';
             $File::Find::name =~ s!^\./!!;
             if (($opt_i and $File::Find::name =~ m/$opt_i/) || ($File::Find::name =~ m/$last_file/))
             {
                 print "local: IGNORING $File::Find::name\n" if $opt_d;
                 return;
             }
             stat($File::Find::name);
             my $type = -f _ ? 'f' : -d _ ? 'd' : -l $File::Find::name ? 'l' : '?';
             my @dirs = split /\//, $File::Find::name;
	     # Plato Wu,2008/12/03 use cross platform solution: File::stat module
	     my $r;
	     if($type eq "d"){
		 my $st = stat($File::Find::name);
		 $r = $loc{$File::Find::name} = 
		 {
		     md5 => 0,
		     mdtm => $st->mtime,
		     size => $st->size,
		     type => 'd',
		 }
	     }else{
		 open(F, $File::Find::name) or die "open error";
		 binmode(F);
		 my $st = stat($File::Find::name);
		 $r = $loc{$File::Find::name} = 
		 {
		     md5 => Digest::MD5->new->addfile(*F)->hexdigest,
		     mdtm => $st->mtime,
		     size => $st->size,
		     type => $type,
		     
		 };
		 close F;
	     }
# 	     open(F, $File::Find::name) or die "open error";
# 	     binmode(F);
#              my $r = $loc{$File::Find::name} = 
#              {
# 		 # Plato Wu,2008/11/28 do not create MD5 for directory.
#                  md5 => -d _ ? 0 : Digest::MD5->new->addfile(*F)->hexdigest,
#                  mdtm => (stat(_))[9],
#                  size => (stat(_))[7],
#                  type => $type,
                 
#              };
#              close F;
             my $mdtm_form = strftime("%c",localtime($r->{mdtm}));
             print "local: adding $File::Find::name (",
             "$r->{mdtm}, $mdtm_form, $r->{size}, $r->{type})\n" if $opt_d;
         },
     }, '.' );


# Phase 1: Build a representation of what's
# in the remote site
print "\n### Phase 1: Scanning FTP ###\n" if $opt_v;

my $ftp = new Net::FTP ($opt_s, 
                        Timeout         => 999,
                        Debug           => $opt_d, 
                        Passive         => $opt_P,
                        );

die "Failed to connect to server '$opt_s': $!\n" unless $ftp;
die "Failed to login as $opt_u\n" unless $ftp->login($opt_u, $opt_p);
# Plato Wu,2008/11/28 it will be confused if delete this directory in the future.
# Plato Wu,2008/11/28 if directory does not exist then create it.
# unless($ftp->cwd($opt_r)){
#     if($opt_k){
# 	print "need upload all from local\n";
# 	exit;
#     }
#     print "MKDIR $opt_r in remote for sync root directory\n" if $opt_v;
#     $ftp->mkdir($opt_r) or die "Failed to MKDIR $opt_r\n"; 
#     die "Cannot change directory to $opt_r\n" unless $ftp->cwd($opt_r);
# }
die "Cannot change directory to $opt_r\n" unless $ftp->cwd($opt_r);

warn "Failed to set binary mode\n" unless $ftp->binary();

my $needhome = 0;

print "connected\n" if $opt_v;

sub scan_ftp
{
    my $ftp     = shift;
    my $path    = shift;
    my $rrem    = shift;
    print "scan_ftp $ftp, path $path, rrem $rrem\n" if $opt_v;
#    my $rdir = length($path) ? $ftp->dir($path) : $ftp->dir();
    # parse_dir of File:Listing better parses mtime for directories
#    my $rdir = length($path) ? parse_dir($ftp->dir($path)) : parse_dir($ftp->dir());
    my $rdir;
    my @r2dir;

#    $path =~ s/\s/\\ /g;
#    $path = "\"$path\"";

#    print "scan_ftp $ftp, path $path, rrem $rrem\n";

    if (length($path)) {
        # Already in a path
        $ftp->cwd("$opt_r/$path"); 
	# Plato Wu,2008/09/08
	# it enter sub directory, then set a flag to use in the future.
	$needhome = 1;
    } else {
        print "first call\n" if $opt_v;
        $ftp->cwd("$opt_r"); 
    }

    $rdir = parse_dir($ftp->dir());

    return unless $rdir and @$rdir;

#    print "Going through the files in this dir ($path)\n";
    for my $f (@$rdir)
    {
#        print "a file found in this dir ($path)\n";
        next if $f =~ m/^d.+\s\.\.?$/;

#        my @line = split(/\s+/, $f, 9);
#        my $n = (@line == 4) ? $line[3] : $line[8]; # Compatibility with windows FTP
#        next unless defined $n;
#        print "parsing entry (in dir $path)\n";
        my ($n, $type, $size, $mtime, $mode) = @$f;

        my $name = '';
        $name = $path . '/' if $path;
        $name .= $n;

        if ($opt_i and $name =~ m/$opt_i/)
        {
            print "remote: IGNORING $name\n" if $opt_d;
            next;
        }

#        print "name '$name'\n" if $opt_v;

        next if exists $rrem->{$name};

        my $mdtm = ($mtime || 0) + $opt_o;
        $size = $size || 0;
#        my $mdtm = ($ftp->mdtm($name) || 0) + $opt_o;
#        my $size = $ftp->size($name) || 0;
#        my $type = (@line == 4) ? ($line[2] =~/\<DIR\>/i ? 'd' : 'f') : substr($f, 0, 1); # Compatibility with windows FTP

        $type =~ s/-/f/;

        my $mdtm_form = strftime("%c",localtime($mdtm));

        if ($type eq 'd') {
            print "remote: recursing in dir $name: calling scan_ftp($ftp, $name, $rrem)\n" if $opt_v;
            scan_ftp($ftp, $name, $rrem);
        }
#        } else {
            print "remote: adding file $name (offset mtime $mdtm_form)\n" if $opt_v;
            $rrem->{$name} = 
            {
                mdtm => $mdtm,
                size => $size,
                type => $type,
		# Plato Wu,2008/12/25: scan ftp can not get MD5.
		md5 => 0,
            }
#        }
    }
}
# Plato Wu,2008/09/06
if ($ftp->get($last_file, $last_file."remote")){
    # it seems no using
    # To do use parse_dir instead of mdtm for some ftp does not support it.
#    utime $ftp->mdtm($last_file), $ftp->mdtm($last_file), $last_file."remote";
    my $hash_ref = retrieve $last_file."remote";
    %rem = %$hash_ref;
    unlink $last_file."remote";
}else{
    scan_ftp($ftp, '', \%rem);
}
# Plato Wu,2008/12/03 cwd must need / to goto home directory.
$ftp->cwd("/$opt_r") or die "Failed to CWD /$opt_r\n" if $needhome;

#
# Phase 2: Handle missing files
#
print "\n### Phase 2: Missing files ###\n" if $opt_v;

# Algorithm
# If file is older than last sync delete it
# If file is newer than last sync sync it

# For local files:
for my $ml (sort { length($a) <=> length($b) } keys %loc)
{
    if ($loc{$ml}->{type} eq 'l')
    {
        warn "Symbolic link $ml not supported\n";
        next;
    }
        
    # Skip if file/dir exists also remotely (will be handled in phase 3)
    next if exists $rem{$ml};

    # File/dir exists locally but not remotely
    print "$ml file/dir missing from the FTP repository\n" if $opt_v;

    # Check if newer than last sync
    print "mdtm $loc{$ml}->{mdtm} last $last\n" if $opt_v;
    if ($loc{$ml}->{mdtm} > $last) {
        # Newer, so copy to remote
       if ($loc{$ml}->{type} eq 'd')
       {
            print "$ml dir missing remotely, making remotely\n" if $opt_v;
            $opt_k ? print "Kidding: MKDIR $ml\n" : $ftp->mkdir($ml)
                or die "Failed to MKDIR $ml\n";
       }
       else # Regular file
       {
            print "$ml file missing remotely, PUTting\n" if $opt_v;
            $opt_k ? print "Kidding: PUT $ml $ml\n" : $ftp->put($ml, $ml)
                or die "*** Failed to PUT $ml ***\n";
       }
    } else {
        # Local file older than last sync, so deleted from remote. Also delete locally
        if ($loc{$ml}->{type} eq 'd') {
            print "$ml dir removed remotely, removing locally\n" if $opt_v;
            $opt_k ? print "Kidding: rmdir $ml\n" : rmdir($ml)
                or die "*** Failed to rmdir dir $ml ***\n";
        } else {
            print "$ml file removed remotely, removing locally\n" if $opt_v;
            $opt_k ? print "Kidding: rm $ml\n" : unlink($ml)
                or die "*** Failed to rm $ml ***\n";
        }
	# Plato Wu,2008/09/07
        # maintain %loc
	delete $loc{$ml};

    }
}

# For remote files:
for my $mr (sort { length($a) <=> length($b) } keys %rem)
{
    if ($rem{$mr}->{type} eq 'l')
    {
        warn "Symbolic link $mr not supported\n";
        next;
    }
        
    # Skip if file/dir exists also locally (will be handled in phase 3)
    next if exists $loc{$mr};

    print "$mr file/dir missing locally\n" if $opt_v;

    # Check if newer than last sync
    print "mdtm $rem{$mr}->{mdtm} last $last\n" if $opt_v;
    if ($rem{$mr}->{mdtm} > $last) {
	# Plato Wu,2008/09/07
        # maintain %loc
	$loc{$mr} = $rem{$mr};
	
        # Newer, so copy to local
        if ($rem{$mr}->{type} eq 'd') {
            print "$mr dir missing in the local repository, making locally\n" if $opt_v;
            $opt_k ? print "Kidding: mkdir $mr\n" : mkdir($mr)
                or die "*** Failed to MKDIR $mr ***\n";
        } else {
            print "$mr file missing in the local repository, GETting\n" if $opt_v;
            $opt_k ? print "Kidding: GET $mr $mr\n" : $ftp->get($mr, $mr)
                or die "*** Failed to GET $mr ***\n";
        }
        # Added EZ: Set the file time to the mdtm
        my $mdtm_form = strftime("%c",localtime($rem{$mr}->{mdtm}));
        print "Setting mtime $mdtm_form to local $mr\n" if $opt_v;
        $opt_k ? print "Kidding: Set Utime\n" : utime $rem{$mr}->{mdtm}, $rem{$mr}->{mdtm}, $mr;

    } else {
        # Remote file older than last sync, so deleted locally
        # Also delete remotely
        if ($rem{$mr}->{type} eq 'd') {
            print "$mr dir deleted locally, removing remotely\n" if $opt_v;
            $opt_k ? print "Kidding: ftp->rmdir $mr\n" : $ftp->rmdir($mr)
                or die "*** Failed to remote rmdir $mr ***\n";
        } else {
            print "$mr file deleted locally, removing remotely\n" if $opt_v;
            $opt_k ? print "Kidding: ftp->delete $mr\n" : $ftp->delete($mr)
                or die "*** Failed to remote delete $mr ***\n";
        }
    }
}

#
# Phase 3: For files that exist on both sides
#
print "\n### Phase 3: Files on both sides ###\n" if $opt_v;

# For remote files: Download if newer
for my $dl (sort { length($a) <=> length($b) } keys %rem)
{
    # only handle files that exist on both sides
    next if not exists $loc{$dl};

    warn "Symbolic link $dl not supported\n"
        if $rem{$dl}->{type} eq 'l';
   
    # forget dirs?
    if ($rem{$dl}->{type} eq 'f')
    {
	# Plato Wu,2008/09/07
	# remarks for handle exactly problem in the other place
	# Skip if exactly the same size
#         next if $rem{$dl}->{size} eq $loc{$dl}->{size};

	# Skip if remote older (local newer)
         next if $rem{$dl}->{mdtm} <= $loc{$dl}->{mdtm};

#        # If remote smaller, remove remote and PUT
#        if ($rem{$dl}->{size} < $loc{$dl}->{size})
#        {
#            print "$dl file smaller in the remote repository ";
#            print "(local: $loc{$dl}->{size} remote: $rem{$dl}->{size})\n";
#            print "DELETEing\n"; 
#            $opt_k ? print "Kidding: ftp->delete $dl\n" : $ftp->delete($dl)
#                or die "*** Failed to remote delete $dl ***\n";
#            print "PUTting\n"; 
#            $opt_k ? print "Kidding: PUT $dl $dl\n" : $ftp->put($dl, $dl)
#                or die "*** Failed to PUT $dl ***\n";
#        } else {

        # GET if file local older
        my $mdtm_form_loc = strftime("%c",localtime($loc{$dl}->{mdtm}));
        my $mdtm_form_rem = strftime("%c",localtime($rem{$dl}->{mdtm}));

	# Plato Wu,2008/09/07
	# next if exactly the same size and md5 checksum
	if (($rem{$dl}->{size} eq $loc{$dl}->{size}) && ($rem{$dl}->{md5} eq $loc{$dl}->{md5})){
	    if($rem{$dl}->{mdtm} > $loc{$dl}->{mdtm}){
	        print "Setting mtime $mdtm_form_rem to local $dl\n" if $opt_v;
                $opt_k ? print "Kidding: Set Utime\n" : utime $rem{$dl}->{mdtm}, $rem{$dl}->{mdtm}, $dl;
	    }
	    next;
	}

	 # Plato, 08/09/06
	 # if remote > local >= last sync, it mean there is a conflict after last sync
	 # use = for cautious
	 if ($loc{$dl}->{mdtm} >= $last) {
	     print "there is a newer file $dl in local and cause a conflict, please handle it\n";
             print $mdtm_form_loc, ",", $mdtm_form_rem, ",", $mdtm_form, "\n";
	     next;
	 }

        if ($opt_v)
        {
            print "$dl file older in the local repository ";
            print "(local: $loc{$dl}->{mdtm} $mdtm_form_loc remote: $rem{$dl}->{mdtm}) $mdtm_form_rem\n";
            print "GETting\n" 
        }
         $opt_k ? print "Kidding: GET $dl $dl\n" : $ftp->get($dl, $dl)
             or die "*** Failed to GET $dl ***\n";

         # Added EZ: Set the file time to the mdtm
         print "Setting mtime $mdtm_form_rem to local $dl\n" if $opt_v;
         $opt_k ? print "Kidding: Set Utime\n" : utime $rem{$dl}->{mdtm}, $rem{$dl}->{mdtm}, $dl;

	# Plato Wu,2008/09/07
        # maintain %loc for put it in the future.
	$loc{$dl} = $rem{$dl};

        }
#    }
}

# For local files: Upload if newer
for my $ul (sort { length($a) <=> length($b) } keys %loc)
{
    # only handle files that exist on both sides
    next if not exists $rem{$ul};

    warn "Symbolic link $ul not supported\n"
        if $loc{$ul}->{type} eq 'l';

    if ($loc{$ul}->{type} eq 'f')
    {
	# Skip if local older (remote newer)
	# fix with 100s for rounding errors
	# Plato Wu,2008/09/08
	# now it does not need fix rounding error for it use actual modification time
	# not ftp put time.
#         next if ($rem{$ul}->{mdtm} + 100) >= $loc{$ul}->{mdtm};
	  next if $rem{$ul}->{mdtm} >= $loc{$ul}->{mdtm};

	  # Plato Wu,2008/09/07
	  # next if exactly the same size and md5 checksum
	  next if ($rem{$ul}->{size} eq $loc{$ul}->{size}) && ($rem{$ul}->{md5} eq $loc{$ul}->{md5}) ;


	  # PUT if file remote older
	  my $mdtm_form_loc = strftime("%c",localtime($loc{$ul}->{mdtm}));
	  my $mdtm_form_rem = strftime("%c",localtime($rem{$ul}->{mdtm}));


	 # Plato, 08/09/06
	 # if local > remote >= last sync, it mean there is a conflict after last sync
	 # use = for cautious
	 if ($rem{$ul}->{mdtm} >= $last) {
	     print "there is a newer file $ul in remote and cause a conflict, please handle it\n";
             print $mdtm_form_loc, ",", $mdtm_form_rem, ",", $mdtm_form, "\n";

	     next;
	 }



        if ($opt_v)
        {
            print "$ul file older in the FTP repository ";
            print "(local: $loc{$ul}->{mdtm} $mdtm_form_loc remote: $rem{$ul}->{mdtm}) $mdtm_form_rem\n";
            print "PUTting\n" 
        }
         $opt_k ? print "Kidding: PUT $ul $ul\n" : $ftp->put($ul, $ul)
             or die "*** Failed to PUT $ul ***\n";
    }
}

# Update last sync time
my $now = time;
# Plato, 08/09/05, if file does not exist, utime can not create it, so add a open & close sentence
# $opt_k ? print "Kidding: TOUCH $last_file\n" : utime $now, $now, $last_file or (open F, ">$last_file") && (close F);

# Plato Wu,2008/12/11: decide whether update local file information.
my $need_update=0;
if(-e $last_file){
    my $hash_ref = retrieve $last_file;
    my %loc_old = %$hash_ref;
    if(scalar keys %loc != scalar keys %loc_old){
#	print "need update: length not equal\n";
	$need_update = 1;
    }else{
	while (my ($k, $v) = each %loc)
	{
	    if ((exists $loc_old{$k}) && ($v->{mdtm} eq $loc_old{$k}->{mdtm}) &&
		($v->{size} eq $loc_old{$k}->{size}) && ($v->{type} eq $loc_old{$k}->{type})
		&& ($v->{md5} eq $loc_old{$k}->{md5})
		){
		next;
	    }else{
# Plato Wu,2009/03/02: some file'smdtm has 1 second inaccurancy and
# need update? To check
		print "$k\n";
		print "need update:$v->{mdtm}, $loc_old{$k}->{mdtm}\n";
		print "$v->{md5},$loc_old{$k}->{md5}";
		$need_update = 1;
		last;
	    }
	}
    }
}else{
#    print "need update:no lastfile";
    $need_update = 1;
}
if($need_update){
# Plato Wu,2008/09/06
# save local file information
    if($opt_k){
	print "Kidding: Store sync file\n"
    }else{
	open F, ">$last_file"; #or print "open error";
	store \%loc, $last_file; # or print "write error";
	close F;
    }
# open F, ">$last_file"; #or print "open error";
# $opt_k ? print "Kidding: Store sync file\n" : store \%loc, $last_file;
# # or print "write error";
# close F;

# Plato Wu,2008/09/07
    $opt_k ? print "Kidding: PUT $last_file\n" : $ftp->put($last_file, $last_file)
	or die "*** Failed to PUT $last_file ***\n";
    if($opt_k)
    {
	while(1){
	    print "Would you like to really synchronize (y/n)?";
	    my $answer=<>;
	    chomp($answer); #removes newline
	    if ($answer eq "y") {
		#print "yes\n";
		$opt_k = 0;
		goto kidorreally;
	    } elsif  ($answer eq "n") {
		#print "no\n";
		last;
	    } else {
		print "Wrong key\n";
	    }
	}

    }
}else{
    print "Nothing to do!\n";
}
print "### Done ###\n";

__END__

=pod

=head1 NAME

ftpsync - Sync a hierarchy of local files with a remote FTP repository

=head1 SYNOPSIS

ftpsync [-h] [-v] [-d] [-k] [-P] [-s server] [-u username] [-p password] [-r remote] [-l local] [-i ignore] [-o offset]

=head1 ARGUMENTS

The recognized flags are described below:

=over 2

=item B<-h>

Produce this documentation.

=item B<-v>

Produce verbose messages while running.

=item B<-d>

Put the C<Net::FTP> object in debug mode and also emit some debugging
information about what's being done.

=item B<-k>

Just kidding. Only announce what would be done but make no change in
neither local nor remote files.

=item B<-P>

Set passive mode.

=item B<-i ignore>

Specifies a regexp. Files matching this regexp will be left alone.

=item B<-s server>

Specify the FTP server to use. Defaults to C<localhost>.

=item B<-u username>

Specify the username. Defaults to 'anonymous'.

=item B<-p password>

Password used for connection. Defaults to an anonymous pseudo-email
address.

=item B<-r remote>

Specifies the remote directory to match against the local directory.

=item B<-l local>

Specifies the local directory to match against the remote directory.

=item B<-o offset>

Allows the specification of a time offset between the FTP server and
the local host. This makes it easier to correct time skew or
differences in time zones.

=back

=head1 DESCRIPTION

This is an example script that should be usable as is for simple
website maintenance. It synchronizes a hierarchy of local files /
directories with a subtree of an FTP server.

The synchronyzation is quite simplistic. It was written to explain how
to C<use Net::FTP> and C<File::Find>.

Always use the C<-k> option before using it in production, to avoid
data loss.

=head1 BUGS

The synchronization is not quite complete. This script does not deal
with symbolic links. Many cases are not handled to keep the code short
and understandable.

=head1 AUTHORS

Luis E. Muñoz <luismunoz@cpan.org>

=head1 SEE ALSO

Perl(1).

=cut


