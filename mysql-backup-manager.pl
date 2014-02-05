#!/usr/bin/perl

#
#  Copyright 2014 Polyvore 
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
#


use strict;

use Config::Tiny;
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Path;
use Getopt::Long;
use IO::File;
use IO::Socket;
use POSIX ":sys_wait_h";
use Sys::Syslog qw(:standard :macros);

my (%parameters, %locations);

# Save the full command line before GetOptions Clobbers it
$parameters{"commandline"} = $0;
for my $param (@ARGV) {
    $parameters{"commandline"} .= " $param";
}

GetOptions(
    'help'                => \$parameters{"help"},
    'host=s'              => \$parameters{"host"},
    'dir=s'               => \$parameters{"dir"},
    'tardir=s'            => \$parameters{"tardir"},
    'deploytemplatedir=s' => \$parameters{"deploytemplatedir"},
    'dbtype=s'            => \$parameters{"dbtype"},
    'timestamp'           => \$parameters{"timestamp"},
    'tarball'             => \$parameters{"tarball"},
    'tarsplit'            => \$parameters{"tarsplit"},
    'verbose'             => \$parameters{"verbose"},
    'encrypt'             => \$parameters{"encrypt"},
    'password=s'          => \$parameters{"password"},
    'upload'              => \$parameters{"upload"},
    's3path=s'            => \$parameters{"s3path"},
    's3cmdconf=s'         => \$parameters{"s3cmdconf"},
    'deletedeploy'        => \$parameters{"deletedeploy"},
    'deletetar'           => \$parameters{"deletetar"},
    'deleteall'           => \$parameters{"deleteall"},
    'transport=s'         => \$parameters{"transport"},
    'mysqlhome=s'         => \$parameters{"mysqlhome"},
    'conf=s'              => \$parameters{"conf"},
);

# Read in config file for any default parameters
if (!$parameters{"conf"}) {
    $parameters{"conf"} = "/etc/mysql-backup-manager.cnf";
}
my $config = Config::Tiny->read($parameters{"conf"});
for my $key (keys %{ $config->{"mysql-backup-manager"} }) {
    if (!$parameters{$key}) {
        $parameters{$key} = $config->{"mysql-backup-manager"}{$key};
    }
}

# This checks for errors in calling syntax - and also fills in some implied parameter values
%parameters = CheckUsage(%parameters);
# fill in file locations from parameters - into its own hash
%locations = SetLocations(%parameters);

mkpath($locations{"basedir"});

# Output status information - and metadata about this script execution
my $statustext = "";
$statustext .= "\nBackup started\n";
$statustext .= "Start Time: " . GetNowString() . "\n";
$statustext .= "Started with command:\n";
$statustext .= "   " . $parameters{"commandline"};
$statustext .= "\nDBType: " . $parameters{"dbtype"};
$statustext .= "\nTransport: " . $parameters{"transport"};
$statustext .= "\nMysql_home: " . $locations{"mysqlhome"};
$statustext .= "\nBasedir: " . $locations{"basedir"};
$statustext .= "\nBackupdir: " . $locations{"backupdir"};
$statustext .= "\nDeploydir: " . $locations{"deploydir"};
$statustext .= "\nDeployTemplateDir: " . $locations{"deploytemplatedir"};
$statustext .= "\nFullTardir: " . $locations{"fulltardir"};
$statustext .= "\nFullS3Path: " . $locations{"fulls3path"};
$statustext .= "\n";
OutputStatus($statustext, $locations{"statusfile"}, $parameters{"verbose"});
ReportPhase("entirebackup", "started", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});

#
# Do the initial backup ( copy phase )
ReportPhase("copy", "started", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
if ($parameters{"transport"} eq "local") {
    CopyPhaseLocal({
            destdir   => $locations{"backupdir"},
            basedir   => $locations{"basedir"},
            mysqlhome => $locations{"mysqlhome"},
    });
}
if ($parameters{"transport"} eq "ssh") {
    CopyPhaseSsh({
            db_host => $parameters{"host"},
            destdir => $locations{"backupdir"},
            basedir => $locations{"basedir"},
    });
}
if ($parameters{"transport"} eq "netcat") {
    CopyPhaseNetcat({
            db_host => $parameters{"host"},
            destdir => $locations{"backupdir"},
            basedir => $locations{"basedir"},
    });
}
ReportPhase("copy", "finished", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});

#
# Apply logs to finish the snapshot
ReportPhase("applylogs", "started", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
ApplyLogsPhase({
        destdir => $locations{"backupdir"},
        basedir => $locations{"basedir"},
});
ReportPhase("applylogs", "finished", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});

# Log the size of the backup directory
my $sizecmd    = "du -bs " . $locations{"backupdir"} . " | awk '{print \$1}'";
my $backupsize = `$sizecmd`;
chomp $backupsize;
my $humanbackupsize  = BytesToHumanReadable($backupsize);
my $backupsizestring = "Backup size was $backupsize ( $humanbackupsize ) - including empty innodb log files\n";
OutputStatus($backupsizestring, $locations{"statusfile"}, $parameters{"verbose"});
OutputLog("dbtype=" . $parameters{"dbtype"} . " backupsize=$backupsize");

#
# Deploy the database - move files around to where we expect them to be
ReportPhase("deploy", "started", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
DeployPhase({
        deploydir         => $locations{"deploydir"},
        backupdir         => $locations{"backupdir"},
        deploytemplatedir => $locations{"deploytemplatedir"},
});
ReportPhase("deploy", "finished", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});

#
# Tar phase
if ($parameters{"tarball"} || $parameters{"tarsplit"}) {
    ReportPhase("tar", "started", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
    my $restoreString = TarPhase({
            deploydir  => $locations{"deploydir"},
            fulltardir => $locations{"fulltardir"},
            password   => $parameters{"password"},
            encrypt    => $parameters{"encrypt"},
            tarball    => $parameters{"tarball"},
            tarsplit   => $parameters{"tarsplit"},
            dbtype     => $parameters{"dbtype"},
    });
    OutputStatus($restoreString, $locations{"statusfile"}, $parameters{"verbose"});
    ReportPhase("tar", "finished", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});

    # Log the size of the tar directory
    my $sizecmd = "du -bs " . $locations{"fulltardir"} . " | awk '{print \$1}'";
    my $tarsize = `$sizecmd`;
    chomp $tarsize;
    my $humantarsize  = BytesToHumanReadable($tarsize);
    my $tarsizestring = "Tar size was $tarsize ( $humantarsize )\n";
    OutputStatus($tarsizestring, $locations{"statusfile"}, $parameters{"verbose"});
    OutputLog("dbtype=" . $parameters{"dbtype"} . " tarsize=$tarsize");
}

#
# Delete the deploy dir if we dont want to keep it
if ($parameters{"deletedeploy"} || $parameters{"deleteall"}) {
    my $deleteCmd = "rm -r " . $locations{"deploydir"};
    my $touchCmd  = "touch " . $locations{"basedir"} . "/deploy-deleted";
    `$deleteCmd`;
    `$touchCmd`;
    my $statusString = "Deleted deploy dir after tar step.\n";
    OutputStatus($statusString, $locations{"statusfile"}, $parameters{"verbose"});
}

#
# Upload
if ($parameters{"upload"}) {
    ReportPhase("upload", "started", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
    UploadPhase({
            fulltardir => $locations{"fulltardir"},
            fulls3path => $locations{"fulls3path"},
            basedir    => $locations{"basedir"},
            s3cmdconf  => $parameters{"s3cmdconf"},
    });
    my $uploadstring
      = "Uploading to "
      . $locations{"fulls3path"}
      . "\nYou can retrieve it with:\n   s3cmd get --recursive "
      . $locations{"fulls3path"} . "\n";
    OutputStatus($uploadstring, $locations{"statusfile"}, $parameters{"verbose"});
    ReportPhase("upload", "finished", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
}

#
# Delete the tar dir if we dont want to keep it
if ($parameters{"deletetar"} || $parameters{"deleteall"}) {
    my $deleteCmd = "rm -r " . $locations{"fulltardir"};
    my $touchCmd  = "touch " . $locations{"basedir"} . "/tar-deleted";
    `$deleteCmd`;
    `$touchCmd`;
    my $statusString = "Deleted tar dir after upload step.\n";
    OutputStatus($statusString, $locations{"statusfile"}, $parameters{"verbose"});
}

#
# We are done - log a few things and clean up
my $touchcmd = "touch " . $locations{"basedir"} . "/done";
system($touchcmd);
ReportPhase("entirebackup", "finished", $parameters{"dbtype"}, $locations{"statusfile"}, $parameters{"verbose"});
exit();


sub CopyPhaseLocal {
    my $params    = shift;
    my $destdir   = $params->{"destdir"};
    my $mysqlhome = $params->{"mysqlhome"};
    my $basedir   = $params->{"basedir"};

    my ($backupcmd, $backupoutput);

    my $envSetString = "";
    my $socketString = "";
    if ($mysqlhome) {
        $envSetString = "MYSQL_HOME=$mysqlhome";
        $socketString = "--socket=$mysqlhome/run/mysql.sock";
    }

    $backupcmd
      = qq{$envSetString innobackupex $socketString --slave-info --safe-slave-backup --no-timestamp $destdir 2> $basedir/backup_output};

    # there shouldn't actually be any output here - we are redirecting the hell out of it
    $backupoutput = `$backupcmd`;

    CheckBackupOutput($backupoutput, "$basedir/backup_output");

}


sub CopyPhaseSsh {
    my $params  = shift;
    my $destdir = $params->{"destdir"};
    my $db_host = $params->{"db_host"};
    my $basedir = $params->{"basedir"};

    my ($backupcmd, $backupoutput);

    mkpath("$destdir");
    chdir("$destdir") || Error(qq{Could not cd to "$destdir"});

    $backupcmd
      = qq{ssh -c blowfish root\@$db_host 'sh -c "innobackupex --stream=tar --slave-info --safe-slave-backup /tmp"' 2> $basedir/backup_output | tar xif - };

    # there shouldn't actually be any output here - we are redirecting the hell out of it
    $backupoutput = `$backupcmd`;

    CheckBackupOutput($backupoutput, "$basedir/backup_output");

}


sub CopyPhaseNetcat {
    my $params  = shift;
    my $destdir = $params->{"destdir"};
    my $db_host = $params->{"db_host"};
    my $basedir = $params->{"basedir"};

    my ($backupcmd, $backupoutput);
    my $hostname = `hostname --fqdn`;
    chomp $hostname;

    mkpath("$destdir");
    chdir("$destdir") || Error(qq{Could not cd to "$destdir"});

    my ($nc, $nc_port, $pid, $nc_cmd);
    $nc_port = find_random_tcp_port();

    # netcat parameters are different for different distros of linux.  you may need to tweak this for your purposes.  We use Debian.
    $nc_cmd = "|nc -l -p $nc_port | tar xif - ";
    my $file = IO::File->new($nc_cmd);
    # we cannot check file to ensure that the netcat port is bound properly - netcat will pretend things worked - even if you give it a used port

    $backupcmd
      = qq{ssh -c blowfish root\@$db_host 'sh -c "innobackupex --stream=tar --slave-info --safe-slave-backup /tmp | nc $hostname $nc_port -q 0"' 2> $basedir/backup_output};

    # there shouldn't actually be any output here - we are redirecting the hell out of it
    $backupoutput = `$backupcmd`;

    CheckBackupOutput($backupoutput, "$basedir/backup_output");
}


# Find out random unused high TCP port
# this function is not mathematically correct.  or good.  but it is good enough
# ie - could select the same random number 10 times.  all ports could be used already
# there could be a race condition between selecting the port number and using it.
# but in practice these occurances dont really happen, so we ignore the possibilities for now.
# tl;dr it's easier to write a long comment on how a function sucks than to fix the problem
sub find_random_tcp_port {
    my $port  = int(10000 + rand(1024));
    my $count = 0;

    while ($count < 10) {
        # attempt to connect to the chosen port - when the connect fails, we have an unused port
        my $socket = IO::Socket::INET->new(
            PeerHost => 'localhost',
            PeerPort => $port,
            Proto    => 'tcp',
        ) or return $port;

        $socket->close();
        $port = int(10000 + rand(1024));
        $count++;
    }
    Error("Unable to find an unused TCP port after $count attempts", "error:tcp_port");
}

sub CheckBackupOutput {

    my ($backupoutput, $outputfile) = @_;

    # check the backup tool output - for success message
    my $backup_fh;
    open($backup_fh, "<", $outputfile);
    if (!grep {/innobackupex: completed OK!/} <$backup_fh>) {
        Error("Error doing initial copy phase", "error:copy_phase");
    }
    close $backup_fh;

}

sub ApplyLogsPhase {

    my $params  = shift;
    my $destdir = $params->{destdir};
    my $basedir = $params->{basedir};

    # In our environment, applying logs fails if we dont use the fast checksumming - add it to the my.cnf that apply logs uses
    # You may want / need to skip this step
    my $mycnf_fh;
    open($mycnf_fh, ">>", "$destdir/backup-my.cnf");
    print $mycnf_fh "\ninnodb_fast_checksum=1\n";
    close($mycnf_fh);

    my $usemem = " --use-memory=1G ";
    my $applylogscommand
      = qq{innobackupex --apply-log $destdir --defaults-file=$destdir/backup-my.cnf --ibbackup=xtrabackup 2> $basedir/applylogs_output};
    my $applylogsoutput = `$applylogscommand`;

    # Check for success
    my $apply_fh;
    open($apply_fh, "<", "$basedir/applylogs_output");
    if (!grep {/innobackupex: completed OK!/} <$apply_fh>) {
        Error("Error applying logs", "error:apply_logs_phase");
    }
    close $apply_fh;

}

# We use a different file and directory layout from default
# Logs, data, temp dirs and sockets and pid files all live in a common tree.
# Log files have been moved out of the default data directory location into the logs directory
# and are further organized into innodb log files, relaylogs and binlogs.
# This allows us to run multiple mysql instances on the same host; with each one isolated within it's
# own directory.
# If you do not like this layout, this is the subroutine to edit
sub DeployPhase {
    my $params            = shift;
    my $deploydir         = $params->{"deploydir"};
    my $backupdir         = $params->{"backupdir"};
    my $deploytemplatedir = $params->{"deploytemplatedir"};

    # make the directories if they dont exist - clear them out if they do
    mkpath(["$deploydir/data",         "$deploydir/logs/innodb",
            "$deploydir/logs/binlogs", "$deploydir/logs/relaylogs",
            "$deploydir/tmp",          "$deploydir/run"
        ]);
    rmtree("$deploydir/data",           { keep_root => 1 });
    rmtree("$deploydir/logs/innodb",    { keep_root => 1 });
    rmtree("$deploydir/logs/binlogs",   { keep_root => 1 });
    rmtree("$deploydir/logs/relaylogs", { keep_root => 1 });
    rmtree("$deploydir/tmp",            { keep_root => 1 });

    move("$backupdir/ib_logfile0", "$deploydir/logs/innodb/ib_logfile0");
    move("$backupdir/ib_logfile1", "$deploydir/logs/innodb/ib_logfile1");
    move("$backupdir",             "$deploydir/data");

    system(qq{chown -R mysql:mysql $deploydir/*});

    if ($locations{"deploytemplatedir"}) {
        my @files = grep {-f} glob("$deploytemplatedir/*");
        for my $file (@files) {
            copy($file, $deploydir);
            my $newfilename = $deploydir . "/" . basename($file);
            my $sedcmd      = qq{sed -i "s#DEPLOYDIR#$deploydir#g" $newfilename };
            system($sedcmd);
        }
        chmod 755, "$deploydir/connect.sh";
        chmod 755, "$deploydir/start.sh";
        chmod 755, "$deploydir/stop.sh";
    }

}

sub TarPhase {

    my $params     = shift;
    my $deploydir  = $params->{"deploydir"};
    my $fulltardir = $params->{"fulltardir"};
    my $password   = $params->{"password"};
    my $encrypt    = $params->{"encrypt"};
    my $tarball    = $params->{"tarball"};
    my $tarsplit   = $params->{"tarsplit"};
    my $dbtype     = $params->{"dbtype"};

    my $restoreString;

    # settings
    my $encryptcmd = "";
    my $encryptext = "";
    if ($encrypt) {
        $encryptcmd = " | openssl des3 -salt -k $password ";
        $encryptext = ".encrypted";
    }

    # Create Tar
    if ($tarball) {
        mkpath("$fulltardir");
        my $tarfilename = "$fulltardir/$dbtype.tgz";
        my $tarcmd      = qq{tar c -C $deploydir . | gzip -c $encryptcmd > $tarfilename$encryptext };
        if ($encrypt) {
            $restoreString
              = "The tar is encrypted.  To decrypt ( and untar ) use the following command:\n    cat $dbtype.tgz$encryptext | openssl des3 -d -k PASSWORD | tar zxivf -\n";
        }

        my $taroutput = `$tarcmd`;
    }

    # Split into smaller chunks
    if ($tarsplit) {
        mkpath("$fulltardir");
        my $splitfilename = "$fulltardir/$dbtype.tgz$encryptext-split.";
        my $tarcmd
          = qq{tar c -C $deploydir . | gzip -c $encryptcmd | split --bytes=1G --suffix-length=4 --numeric-suffixes - $splitfilename };
        if ($encrypt) {
            $restoreString
              = "The split tar is encrypted.  To decrypt ( and untar ) use the following command:\n    cat $dbtype.tgz$encryptext-split* | openssl des3 -d -k PASSWORD | tar zxivf -\n";
        }

        my $taroutput = `$tarcmd`;
    }

    return $restoreString;

}

sub UploadPhase {

    my $params     = shift;
    my $fulltardir = $params->{"fulltardir"};
    my $fulls3path = $params->{"fulls3path"};
    my $basedir    = $params->{"basedir"};
    my $s3cmdconf  = $params->{"s3cmdconf"};

    # Upload the tar files
    my $uploadcmd    = qq{ /usr/local/bin/s3cmd -c $s3cmdconf -r put $fulltardir $fulls3path 2>&1 };
    my $uploadoutput = `$uploadcmd`;
    if ($uploadoutput =~ m/ERROR/) {
        Error("Error occured uploading to S3");
    }

    # Upload an upload-done file so that we can tell by looking at S3 contents 
    # if the backup/upload is complete
    my $doneuploadcmd          = qq{ touch $basedir/upload-done };
    my $doneuploadoutput       = `$doneuploadcmd`;
    my $uploaddoneuploadcmd    = qq{ s3cmd -c $s3cmdconf -r put $basedir/upload-done $fulls3path/ 2>&1 };
    my $uploaddoneuploadoutput = `$uploaddoneuploadcmd`;
    if ($uploaddoneuploadoutput =~ m/ERROR/) {
        Error("Error occured uploading done file to S3");
    }

}



sub GetNowString {
    my @time = map { sprintf '%02d', $_ } localtime(time);
    my $timestring = join('-', $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1]);
    return $timestring;
}

# Based on the parameters, figure out all of the file locations
sub SetLocations {
    %parameters = @_;
    my %locations;

    if ($parameters{"timestamp"}) {
        my $timestring = GetNowString();
        $locations{"basedir"}    = $parameters{"dir"} . "/$timestring";
        $locations{"fulltardir"} = $parameters{"tardir"} . "/$timestring/tar";
        $locations{"fulls3path"} = $parameters{"s3path"} . "/" . $parameters{"dbtype"} . "/" . $timestring . "/";
    } else {
        $locations{"basedir"}    = $parameters{"dir"};
        $locations{"fulltardir"} = $parameters{"tardir"} . "/tar";
        $locations{"fulls3path"} = $parameters{"s3path"} . "/";
    }
    # If tardir was not specified, overwrite the invalid fulltardir we just set
    if (!$parameters{"tardir"}) {
        $locations{"fulltardir"} = $locations{"basedir"} . "/tar";
    }
    $locations{"backupdir"}  = $locations{"basedir"} . "/backup";
    $locations{"deploydir"}  = $locations{"basedir"} . "/deploy";
    $locations{"statusfile"} = $locations{"basedir"} . "/status";
    if ($parameters{"mysqlhome"}) {
        $locations{"mysqlhome"} = $parameters{"mysqlhome"};
    }
    if ($parameters{"deploytemplatedir"}) {
        $locations{"deploytemplatedir"} = $parameters{"deploytemplatedir"};
    }
    if (!$parameters{"upload"}) {
        $locations{"fulls3path"} = "";
    }

    return %locations;
}

# this is not an actual phase.  It reports and logs how the actual phases went
sub ReportPhase {
    my ($phase, $status, $dbtype, $outputfile, $verbose) = @_;

    our %times;
    my ($timeelapsed, $timestring);
    $times{"$phase-$status"} = time;
    if ($times{ $phase . "-finished" } && $times{ $phase . "-started" }) {
        $timeelapsed = $times{ $phase . "-finished" } - $times{ $phase . "-started" };
        $timestring  = "Phase took $timeelapsed seconds";
    }

    my $basetext = "dbtype=$dbtype phase=$phase status=$status";
    OutputLog($basetext);

    my $statustext = $basetext . " at " . GetNowString() . ".  $timestring\n";
    OutputStatus($statustext, $outputfile, $verbose);
}

sub OutputStatus {
    my ($text, $outputfile, $verbose) = @_;

    if ($verbose) {
        print $text;
    }
    my $summary_fh;
    open($summary_fh, ">>", $outputfile) or Error("Cannot open $outputfile: $!", "error:file_io");
    print $summary_fh $text;
    close $summary_fh;
}

sub BytesToHumanReadable {

    my $size = shift;

    if ($size > 1099511627776) #   TiB: 1024 GiB
    {
        return sprintf("%.2f TiB", $size / 1099511627776);
    } elsif ($size > 1073741824) #   GiB: 1024 MiB
    {
        return sprintf("%.2f GiB", $size / 1073741824);
    } elsif ($size > 1048576)    #   MiB: 1024 KiB
    {
        return sprintf("%.2f MiB", $size / 1048576);
    } elsif ($size > 1024)       #   KiB: 1024 B
    {
        return sprintf("%.2f KiB", $size / 1024);
    } else                       #   bytes
    {
        return sprintf("%.2f bytes", $size);
    }
}

sub OutputLog {
    my $text  = shift;
    my $level = shift;
    if (!$level) {
        $level = LOG_INFO;
    }
    openlog("mysql-backup-manager", "ndelay,pid", LOG_LOCAL0);
    syslog($level, $text);
    closelog();
}

sub Error {
    my $long  = shift;
    my $short = shift;

    if (!$short) {
        $short = $long;
    }
    OutputLog($short, LOG_ERR);
    die $long;
}


sub usage {

    my $usageString = qq{
$0

Summary:

This is a tool for managing the backup process for mysql databases.  It uses the innobackupex tool to do the backup - but automates the process does some niceities in regards to transmitting the backups across the network and uploading them to S3.

This script is always run on the destination server - but can backup a database that exists on another host ( the source server ) without any downtime to mysql on that host.

This script was developed by Polyvore ( www.polyvore.com ).

It logs various timing and status information to syslog.  It also creates a metadata file in the destination directory called "status".

After doing the initial backup, it automatically runs the applylogs step of innobackupex.

It moves files from the default locations into the filestystem layout used by polyvore.  The advantage of this is that it creates a self contained database directory.  When used in combination with the deploytemplatedir option, it will create a .my.cnf file and start and stop scripts to enable you to launch mysql directly from this directory without interfering with other running mysql instances on the server.


Prerequisites:

- You must have root permissions
- You must have root ssh keys set up between this host and the source host
- If you are uploading to S3, you must have the s3cmd installed and configured with your amazon keys
- You must have innobackupex and xtrabackup from Percona installed


Parameters:

--help
	Print this message

--conf
    Load and use a configuration file specified.  Any other parameter that can be specified on the commandline can be set in the config file.  It reads from the [mysql-backup-manager] section of the config.  Each parameter is in the format key=value or key = value.  For example:

        [mysql-backup-manager]
        s3cmdconf=/root/s3cmd.conf
        password=ENCRYPTIONPW
        s3path=s3://bucketname/path
        dbtype=databasename
        deploytemplatedir=/usr/lcoal/share/mysql-deploy-template


--transport
	Valid options for this parameter are "local", "ssh" and "netcat"

	- local:
		Use this option to backup a database on the same server that you are on.
		It is the simpliest and fastest option.

	- ssh:
		Connect to the source server via ssh and stream the data over this connection

	- netcat:
		Use netcat to stream the data between servers.  This is faster than ssh - but lacks any sort of
		security that ssh provides.

		There are some limitations to the netcat method:
			- the source server must be able to connect to the destination server at a random high port
				( between 10000 and 11024 ) via the hostname returned by the "hostname --fqdn" command on
				the destination server.
			- this script was developed on Debian Squeeze.  Netcat implentations vary from OS to OS and from
				distribution to distribution.  If you are using a different distro, you may need to edit
				the script to change how the port is specified on the listener and the "-q 0" parameter
				on the sender. ( these are hard coded into this script )



--host
	The hostname of the source server that you want to back up for netcat or ssh transports


--dir
	The destination directory; your backup will go here.  This parameter is required.

--timestamp
	Create a subdirectory in the base dir, tar dir and upload destination with the current datetime.  This allows you to run the backup command from cron - and directories will be unique and not clobber each other.

--mysqlhome
	If you are backing up a self contained db instance dir - as produced by this script, you can use this option to properly access the my.cnf file and socket file to backup that instance.  If you do not specify this option, it will use the system mysql options.

--tarball
	Create a gzipped tar archive of the deploy directory

--tarsplit
	Create a gzipped tar archive of the deploy directory - split into 1G files.

--encrypt
	Use OpenSSL DES3 encryption to encrypt the tar.  The tarball or tarsplit option must be specified to use this.  To decrypt, use a command like "cat encryptedtaredfilename | openssl des3 -d -k PASSWORD | tar zxivf -".  Instructions for how to decrypt will be also saved in the status file.

--password
	The password to use for the encrypt option.  If you do not specify a password on the command line, it will use a default one.  ( This means that the level of security is determined by controlling access to this script.  But it saves you from having to specify the password in cronjobs and having the password showing up in ps listings ).

--tardir
	If you want the tar files to be stored in a different location - or on a different filesystem, you can specify a
	different directory here.  The specified directory will be created if it does not exist.  A tar directory will be
	created under that.  When combined with the timestamp option, the timestamp directory will be created in the tar
	directory to match the timestamp directory created in the base dir.  common usage: create the backup and apply
	logs on fast RAID/SSDs - then create the tars on slower bulk storage

--dbtype
	If you have multiple databases, you can specify which database this is.  ie- accounting or stats.  This is used in naming files for the tar and upload process.

--deploytemplatedir
	Copy additional files into the deploy dir.  Any files in the template dir will be copied - while replacing the text "DEPLOYDIR" with the actual path of the deploy directory.  With an appropriate my.cnf, start.sh and stop.sh you can have a self contained, instantly launchable database instance.

--upload
	Upload the tar archive to S3.  This assumes that you have s3cmd configured with your amazon keys.  When the upload is complete, it will upload a file named "upload-complete".  Instructions on how to download the file will be saved in the status file.

--s3path
	The s3 path to use for the upload step.  If this is not specified, a default one will be used from the script.  Edit this default to suit your environment.  expected format: "s3://bucket/path".  It will create a subdir for the dbtype and the timestamp if those options were used.  So the final destination for the backup will be "s3://bucket/path/dbtype/datetime/tar".

--s3cmdconf
        The path to the s3cmd configuration file

--deletedeploy
	If your goal is to create a tar and upload to S3, you don't need the deploy directory after the tars are created.  Delete it as soon as possible to recover the disk space.

--deletetar
	If your goal is to create a tar and upload to S3, you don't need the tar directory after the upload is completed.  Delete it as soon as possible to recover the disk space.

--deleteall
	Combines deletedeploy and deletetar into one convenient parameter

--verbose
	Print metadata that goes to the status file to stdout as well.

Example Usage:
        $0 --dbtype=databasename --dir=/srv/db-backups/databasename --tardir=/srv/db-tars/databasename --timestamp --tarsplit --upload --encrypt --password=CHANGEME --deleteall --transport=ssh --host=hostname.domain.com --verbose


}; # end of usage strig qq
    print $usageString;
    exit;

} # end of usage subroutine

sub CheckUsage {

    my %parameters = @_;

    usage() if ($parameters{"help"});
    if (!$parameters{"dir"}) {
        Error("Error: You must specify a target directory (dir)", "error:syntax");
    }
    if ($parameters{"tarball"} && $parameters{"tarsplit"}) {
        Error("Error: You cannot create both a tarball and a split tar archive", "error:syntax");
    }
    if ($parameters{"encrypt"} && !($parameters{"tarball"} || $parameters{"tarsplit"})) {
        Error("Error: You must specify tarball or tarsplit to use crypt", "error:syntax");
    }
    if (!$parameters{"password"} && $parameters{"encrypt"}) {
        Error("Error: You cannot encrypt unless you specify a password", "error:syntax");
    }
    if (!$parameters{"host"} && !$parameters{"transport"}) {
        $parameters{"transport"} = "local";
    }
    if (!$parameters{"transport"}) {
        $parameters{"transport"} = "ssh";
    }
    if (($parameters{"transport"} eq "ssh" || $parameters{"transport"} eq "netcat") && !$parameters{"host"}) {
        Error("Error: You must specify a host if you are using ssh or netcat transport", "error:syntax");
    }
    if (   ($parameters{"transport"} ne "local")
        && ($parameters{"transport"} ne "netcat")
        && ($parameters{"transport"} ne "ssh")) {
        Error("Error: Transport must be either local, netcat or ssh", "error:syntax");
    }
    if ($parameters{"tarball"} || $parameters{"tarsplit"} || $parameters{"upload"}) {
        if (!$parameters{"dbtype"}) {
            Error(
                "Error: If you tar or upload the backup, you must specify a dbtype.  It is used for naming the files created",
                "error:syntax"
            );
        }
    }
    if ($parameters{"upload"}) {
        if (!$parameters{"tarball"} && !$parameters{"tarsplit"}) {
            Error("Error: You must specify tarball or tarsplit in order to upload", "error:syntax");
        }
        if (!$parameters{"s3path"}) {
            Error("Error: You must specify an s3 path in order to upload", "error:syntax");
        }
    }
    if ($parameters{"deleteall"}) {
        if (!(($parameters{"tarball"} || $parameters{"tarsplit"}) && $parameters{"upload"})) {
            Error("Error: You cannot deleteall without a tar option and the upload option specified", "error:syntax");
        }
    }
    if ($parameters{"deletedeploy"}) {
        if (!$parameters{"tarball"} && !$parameters{"tarsplit"}) {
            Error(
                "Error: You cannot automatically delete the deploy directory if you do not have a tar option specified",
                "error:syntax"
            );
        }
    }
    if ($parameters{"deletetar"}) {
        if (!$parameters{"tarball"} && !$parameters{"tarsplit"}) {
            Error("Error: You cannot automatically delete the tar directory if you do not have a tar option specified",
                "error:syntax");
        }
        if (!$parameters{"upload"}) {
            Error(
                "Error: You cannot automatically delete the tar directory if you do not have the upload option specified",
                "error:syntax"
            );
        }
    }

    return %parameters;

}

