=head1 NAME

 autoinstaller::Adapter::Debian - Debian autoinstaller adapter class

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2015 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package autoinstaller::Adapter::Debian;

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use iMSCP::Debug;
use iMSCP::Dialog;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::File;
use iMSCP::Getopt;
use iMSCP::PkgManager;
use iMSCP::ProgramFinder;
use iMSCP::Stepper;
use File::Temp;
use parent 'autoinstaller::Adapter::Abstract';

=head1 DESCRIPTION

 i-MSCP autoinstaller adapter implementation for Debian.

=head1 PUBLIC METHODS

=over 4

=item installPreRequiredPackages()

 Install pre-required packages

 Return int 0 on success, other on failure

=cut

sub installPreRequiredPackages
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeInstallPreRequiredPackages', $self->{'preRequiredPackages'});
	return $rs if $rs;

	$rs = $self->{'package_manager'}->updateIndex();
	return $rs if $rs;

	$rs = $self->{'package_manager'}->installPackages(@{$self->{'preRequiredPackages'}});
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterInstallPreRequiredPackages');
}

=item preBuild()

 Process preBuild tasks

 Return int 0 on success, other on failure

=cut

sub preBuild
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforePreBuild');
	return $rs if $rs;

	unless($main::skippackages) {
		if($main::imscpConfig{'DATABASE_PASSWORD'} ne '' && not $main::reconfigure ~~ [ 'sql', 'servers', 'all' ]) {
			$ENV{'DEBIAN_PRIORITY'} = 'critical';
		}

		my @steps = (
			[ sub { $self->_buildPackageList(); },                 'Building list of packages to install/uninstall' ],
			[ sub { $self->_prefillDebconfDatabase(); },           'Pre-fill debconf database' ],
			[ sub { $self->_processAptRepositories(); },           'Processing APT repositories if any' ],
			[ sub { $self->_processAptPreferences(); },            'Processing APT preferences if any' ],
			[ sub { $self->{'package_manager'}->updateIndex(); },  'Updating packages index' ]
		);

		my $step = 1;
		my $nbSteps = scalar @steps;

		for (@steps) {
			$rs = step($_->[0], $_->[1], $nbSteps, $step);
			return $rs if $rs;
			$step++;
		}
	}

	$self->{'eventManager'}->trigger('afterPreBuild');
}

=item installPackages()

 Install Debian packages

 Return int 0 on success, other on failure

=cut

sub installPackages
{
	my $self = $_[0];

	my $rs = $self->uninstallPackages($self->{'packagesToPreUninstall'});
	return $rs if $rs;

	$rs = $self->{'eventManager'}->trigger(
		'beforeInstallPackages', $self->{'packagesToInstall'}, $self->{'packagesToInstallDelayed'}
	);
	return $rs if $rs;

	for my $packages($self->{'packagesToInstall'}, $self->{'packagesToInstallDelayed'}) {
		if(@{$packages}) {
			$rs = $self->{'package_manager'}->installPackages(@{$packages});
			return $rs if $rs;
		}
	}

	$self->{'eventManager'}->trigger('afterInstallPackages');
}

=item uninstallPackages([ \@packages ])

 Uninstall Debian packages

 Param array \@packages OPTIONAL List of packages to uninstall ( default is list from the packagesToUninstall attribute )
 Return int 0 on success, other on failure

=cut

sub uninstallPackages
{
	my ($self, $packages) = @_;

	$packages ||= $self->{'packagesToUninstall'};

	eval "use List::MoreUtils qw(uniq); 1";
	fatal($@) if $@;

	# Remove any duplicate entry
	# Do not try to remove any packages which were scheduled for installation
	@{$packages} = grep {
		not $_ ~~ [ @{$self->{'packagesToInstall'}}, @{$self->{'packagesToInstallDelayed'}} ]
	} uniq(@{$packages});

	my $rs = $self->{'eventManager'}->trigger('beforeUninstallPackages', $packages);
	return $rs if $rs;

	$rs = $self->{'package_manager'}->uninstallPackages(@{$packages});
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterUninstallPackages');
}

=item postBuild()

 Process postBuild tasks

 Return int 0 on success, other on failure

=cut

sub postBuild
{
	my $self = shift;

	# Needed to fix #IP-1246
	if(iMSCP::ProgramFinder::find('php5dismod')) {
		for (
			'apc', 'curl', 'gd', 'imap', 'intl', 'json', 'mcrypt', 'mysqlnd', 'mysqli', 'mysql', 'opcache', 'pdo',
			'pdo_mysql'
		) {
			my($stdout, $stderr);
			my $rs = execute("php5dismod $_", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			unless($rs ~~ [ 0, 2 ]) {
				error($stderr) if $stderr;
				return $rs;
			}
		}
	}

	# Enable needed PHP modules ( only if they are available )
	if(iMSCP::ProgramFinder::find('php5enmod')) {
		for (
			'apc', 'curl', 'gd', 'imap', 'intl', 'json', 'mcrypt', 'mysqlnd/10', 'mysqli', 'mysql', 'opcache', 'pdo/10',
			'pdo_mysql'
		) {
			my($stdout, $stderr);
			my $rs = execute("php5enmod $_", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			unless($rs ~~ [ 0, 2 ]) {
				error($stderr) if $stderr;
				return $rs;
			}
		}
	}

	$self->_setupInitScriptPolicyLayer('disable');
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return autoinstaller::Adapter::DebianAdapter

=cut

sub _init
{
	my $self = $_[0];

	$self->{'eventManager'} = iMSCP::EventManager->getInstance();

	delete $ENV{'DEBCONF_FORCE_DIALOG'};
	$ENV{'DEBIAN_FRONTEND'} = 'noninteractive' if iMSCP::Getopt->preseed || iMSCP::Getopt->noprompt;

	$self->{'repositorySections'} = [ 'main', 'non-free' ];
	$self->{'preRequiredPackages'} = [
		'aptitude', 'debconf-utils', 'dialog', 'libbit-vector-perl', 'libclass-insideout-perl', 'liblist-moreutils-perl',
		 'libscalar-defer-perl', 'libxml-simple-perl', 'wget', 'rsync'
	];
	$self->{'aptRepositoriesToRemove'} = [];
	$self->{'aptRepositoriesToAdd'} = [];
	$self->{'aptPreferences'} = [];
	$self->{'packagesToInstall'} = [];
	$self->{'packagesToInstallDelayed'} = [];
	$self->{'packagesToPreUninstall'} = [];
	$self->{'packagesToUninstall'} = [];

	$self->{'package_manager'} = iMSCP::PkgManager->getInstance();

	unless($main::skippackages) {
		($self->_setupInitScriptPolicyLayer('enable') == 0 ) or die('Unable to setup initscript policy layer');
		($self->_updateAptSourceList() == 0) or die('Unable to configure APT packages manager');
	}

	$self;
}

=item _setupInitScriptPolicyLayer($action)

 Enable or disable initscript policy layer

 See https://people.debian.org/~hmh/invokerc.d-policyrc.d-specification.txt
 See man invoke-rc.d

 Param string $action Action ( enable|disable )
 Return int 0 on success, other on failure

=cut

sub _setupInitScriptPolicyLayer
{
	my $action = $_[1];
	my $rs = 0;

	if($action eq 'enable') {
		# Prevents invoke-rc.d ( which is invoked by package maintainer scripts ) to start some services
		# apache2 and nginx: This prevents failures such as "bind() to 0.0.0.0:80 failed (98: Address already in use"
		# bind9: This avoid error when resolvconf is not configured yet
		my $file = iMSCP::File->new( filename => '/usr/sbin/policy-rc.d' );
		my $rs = $file->set(<<EOF);
#/bin/sh
initscript=\$1
action=\$2

if [ "\$action" = "start" ] || [ "\$action" = "restart" ]; then
	for i in apache2 bind9 nginx; do
		if [ "\$initscript" = "\$i" ]; then
			exit 101;
		fi
	done
fi
EOF

		$rs ||= $file->save();
		$rs ||= $file->mode(0755);
	} elsif($action eq 'disable') {
		if(-f '/usr/sbin/policy-rc.d') {
			$rs = iMSCP::File->new( filename => '/usr/sbin/policy-rc.d' )->delFile();
		}
	} else {
		error('Unknown action');
		$rs = 1;
	}

	$rs;
}

=item _buildPackageList()

 Build lists of Debian packages to uninstall and install

 Return int 0 on success, other on failure

=cut

sub _buildPackageList
{
	my $self = $_[0];

	my $lsbRelease = iMSCP::LsbRelease->getInstance();
	my $dist = lc($lsbRelease->getId(1));
	my $codename = lc($lsbRelease->getCodename(1));
	my $pkgFile = "$FindBin::Bin/docs/" . ucfirst($dist) . "/packages-$codename.xml";

	eval "use XML::Simple; 1";
	fatal($@) if $@;

	my $xml = XML::Simple->new(NoEscape => 1);
	my $pkgList = eval { $xml->XMLin($pkgFile, ForceArray => [ 'package', 'package_delayed', 'package_conflict' ]) };

	unless($@) {
		# For each package section found in package list
		for my $section(sort keys %{$pkgList}) {
			if(exists $pkgList->{$section}->{'package'} || exists $pkgList->{$section}->{'package_delayed'}) {
				# Simple list of packages to install

				if(exists $pkgList->{$section}->{'package'}) {
					push @{$self->{'packagesToInstall'}}, @{$pkgList->{$section}->{'package'}};
				}

				if(exists $pkgList->{$section}->{'package_delayed'}) {
					push @{$self->{'packagesToInstallDelayed'}}, @{$pkgList->{$section}->{'package_delayed'}};
				}
			} else {
				# List of alternative services

				my $dAlt = delete $pkgList->{$section}->{'default'};
				my $sAlt = $main::questions{ uc($section) . '_SERVER' } || $main::imscpConfig{ uc($section) . '_SERVER' };
				my $forceDialog = ($sAlt) ? 0 : 1;
				$sAlt = $dAlt if $forceDialog;

				my @alts = keys %{$pkgList->{$section}};

				if(not $sAlt ~~ @alts) { # Handle wrong or deprecated entry case
					$sAlt = $dAlt;
					$forceDialog = 1;
				}

				if(exists $pkgList->{$section}->{$sAlt}->{'allow_switch_to'}) {
					if($pkgList->{$section}->{$sAlt}->{'allow_switch_to'} ne '') {
						my @allowedAlts = (split(',', $pkgList->{$section}->{$sAlt}->{'allow_switch_to'}), $sAlt);
						@alts = grep { $section ~~ @allowedAlts } @alts;
					} else {
						@alts = ($sAlt);
					}
				}

				@alts = sort @alts;

				# Ask user service to install if needed
				if(@alts > 1 && ($forceDialog || $main::reconfigure ~~ [ $section, 'servers', 'all' ])) {
					iMSCP::Dialog->getInstance()->set('no-cancel', '');
					(my $ret, $sAlt) = iMSCP::Dialog->getInstance()->radiolist(<<EOF, [@alts], $sAlt);

Please, choose the i-MSCP server implementation you want use for the $section service:
EOF
					return $ret if $ret; # Handle ESC case

					iMSCP::Dialog->getInstance()->set('no-cancel');
				}

				if($section eq 'sql') {
					my ($stdout, $stderr);
					my $rs = execute('rm -f /var/lib/mysql/debian-*.flag', \$stdout, \$stderr);
					debug($stdout) if $stdout;
					error($stderr) if $rs && $stderr;
					return $rs if $rs;
				}

				for my $alt(@alts) {
					if($alt ne $sAlt) {
						# APT repository to remove
						if(exists $pkgList->{$section}->{$alt}->{'repository'}) {
							push @{$self->{'aptRepositoriesToRemove'}}, $pkgList->{$section}->{$alt}->{'repository'};
						}

						if(exists $pkgList->{$section}->{$alt}->{'repository_conflict'}) {
							push @{$self->{'aptRepositoriesToRemove'}}, $pkgList->{$section}->{$alt}->{'repository_conflict'};
						}

						# Packages to uninstall

						if(exists $pkgList->{$section}->{$alt}->{'package'}) {
							push @{$self->{'packagesToUninstall'}}, @{$pkgList->{$section}->{$alt}->{'package'}};
						}

						if(exists $pkgList->{$section}->{$alt}->{'package_delayed'}) {
							push @{$self->{'packagesToUninstall'}}, @{$pkgList->{$section}->{$alt}->{'package_delayed'}};
						}
					}
				}

				# APT preferences to add
				if(exists $pkgList->{$section}->{$sAlt}->{'pinning_package'}) {
					push @{$self->{'aptPreferences'}}, {
						'pinning_package' => $pkgList->{$section}->{$sAlt}->{'pinning_package'},
						'pinning_pin' => $pkgList->{$section}->{$sAlt}->{'pinning_pin'} || undef,
						'pinning_pin_priority' => $pkgList->{$section}->{$sAlt}->{'pinning_pin_priority'} || undef,
					};
				}

				# Conflicting repository which must be removed
				if(exists $pkgList->{$section}->{$sAlt}->{'repository_conflict'}) {
					push @{$self->{'aptRepositoriesToRemove'}}, $pkgList->{$section}->{$sAlt}->{'repository_conflict'};
				}

				# APT repository to add
				if(exists $pkgList->{$section}->{$sAlt}->{'repository'}) {
					push @{$self->{'aptRepositoriesToAdd'}}, {
						'repository' => $pkgList->{$section}->{$sAlt}->{'repository'},
						'repository_key_uri' => $pkgList->{$section}->{$sAlt}->{'repository_key_uri'} || undef,
						'repository_key_id' => $pkgList->{$section}->{$sAlt}->{'repository_key_id'} || undef,
						'repository_key_srv' => $pkgList->{$section}->{$sAlt}->{'repository_key_srv'} || undef
					};
				}

				# Conflicting packages which must be pre-removed
				if(exists $pkgList->{$section}->{$sAlt}->{'package_conflict'}) {
					push @{$self->{'packagesToPreUninstall'}}, @{$pkgList->{$section}->{$sAlt}->{'package_conflict'}};
				}

				# Packages to install

				if(exists $pkgList->{$section}->{$sAlt}->{'package'}) {
					push @{$self->{'packagesToInstall'}}, @{$pkgList->{$section}->{$sAlt}->{'package'}};
				}

				if(exists $pkgList->{$section}->{$sAlt}->{'package_delayed'}) {
					push @{$self->{'packagesToInstallDelayed'}}, @{$pkgList->{$section}->{$sAlt}->{'package_delayed'}};
				}

				# Set server implementation to use
				$main::questions{ uc($section) . '_SERVER' } = $sAlt;
			}
		}
	} else {
		error($@);
		return 1;
	}

	0;
}

=item _updateAptSourceList()

 Add required sections to repositories that support them

 Return int 0 on success, other on failure

=cut

sub _updateAptSourceList
{
	my $self = $_[0];

	my $file = iMSCP::File->new( filename => '/etc/apt/sources.list' );

	my $rs = $file->copyFile('/etc/apt/sources.list.bkp') unless -f '/etc/apt/sources.list.bkp';
	return $rs if $rs;

	my $fileContent = $file->get();

	unless (defined $fileContent) {
		error('Unable to read /etc/apt/sources.list file');
		return 1;
	}

	my ($foundSection, $stdout, $stderr);

	for(@{$self->{'repositorySections'}}) {
		my $section = $_;
		my @seen = ();

		while($fileContent =~ /^deb\s+(?<uri>(?:https?|ftp)[^\s]+)\s+(?<distrib>[^\s]+)\s+(?<components>.+)$/gm) {
			my %repository = %+;

			if("$repository{'uri'} $repository{'distrib'}" ~~ @seen) {
				debug("Repository '$repository{'uri'} $repository{'distrib'}' already checked for '$section' section");
				next;
			}

			debug("Checking repository '$repository{'uri'} $repository{'distrib'}' for '$section' section");

			unless($fileContent =~ /^deb\s+$repository{'uri'}\s+\b$repository{'distrib'}\b\s+.*\b$section\b/m) {
				my $uri = "$repository{'uri'}/dists/$repository{'distrib'}/$section/";
				$rs = execute("wget --spider $uri", \$stdout, \$stderr);
				debug($stdout) if $stdout;
				debug($stderr) if $rs && $stderr;

				unless ($rs) {
					$foundSection = 1;
					debug("Enabling section '$section' on '$repository{'uri'} $repository{'distrib'}'");
					$fileContent =~ s/^($&)$/$1 $section/m;
				}
			} else {
				debug("Section '$section' already enabled on '$repository{'uri'} $repository{'distrib'}'");
				$foundSection = 1;
			}

			push @seen, "$repository{'uri'} $repository{'distrib'}";
		}

		unless($foundSection) {
			error("Unable to found repository supporting '$section' section");
			return 1;
		}
	}

	$rs = $file->set($fileContent);
	$rs ||= $file->save();
}

=item _processAptRepositories()

 Process APT repositories

 Return int 0 on success, other on failure

=cut

sub _processAptRepositories
{
	my $self = $_[0];

	if(@{$self->{'aptRepositoriesToRemove'}} || @{$self->{'aptRepositoriesToAdd'}}) {
		my ($stdout, $stderr);
		my @cmd = ();

		my $file = iMSCP::File->new( filename => '/etc/apt/sources.list' );

		my $rs = $file->copyFile('/etc/apt/sources.list.bkp') unless -f '/etc/apt/sources.list.bkp';
		return $rs if $rs;

		my $fileContent = $file->get();
		unless (defined $fileContent) {
			error('Unable to read /etc/apt/sources.list file');
			return 1;
		}

		# Filter list of repositories which must not be removed
		for my $repository(@{$self->{'aptRepositoriesToAdd'}}) {
			@{$self->{'aptRepositoriesToRemove'}} = grep {
				 $repository->{'repository'} !~ /^$_/
			} @{$self->{'aptRepositoriesToRemove'}};
		}

		for my $repository(@{$self->{'aptRepositoriesToRemove'}}) {
			# Remove the repository from the sources.list file
			(my $regexp = $repository) =~ s/deb/(?:#\\s*)?(?:deb|deb-src)/;
			$fileContent =~ s/^\n?$regexp\n//gm;
		}

		# Add needed APT repositories
		for my $repository(@{$self->{'aptRepositoriesToAdd'}}) {
			if($fileContent !~ /^$repository->{'repository'}/m) {
				$fileContent .= "\n$repository->{'repository'}\n";

				@cmd = ();

				if($repository->{'repository_key_srv'}) { # Add the repository key from the given server, using key id
					if($repository->{'repository_key_id'}) {
						@cmd = (
							'apt-key adv --recv-keys --keyserver',
							escapeShell($repository->{'repository_key_srv'}),
							escapeShell($repository->{'repository_key_id'})
						);
					} else {
						error("The repository_key_id entry for the '$repository->{'repository'}' repository was not found");
						return 1;
					}
				} elsif($repository->{'repository_key_uri'}) { # Add the repository key by fetching it from the given URI
					@cmd = ('wget -qO-', escapeShell($repository->{'repository_key_uri'}), '| apt-key add -');
				}

				if(@cmd) {
					$rs = execute("@cmd", \$stdout, \$stderr);
					debug($stdout) if $stdout;
					error($stderr) if $stderr && $rs;
					return $rs if $rs;
				}
			}
		}

		# Save new sources.list file
		$rs = $file->set($fileContent);
		$rs ||= $file->save();
		return $rs if $rs;
	}

	0;
}

=item _processAptPreferences()

 Process apt preferences

 Return 0 on success, other on failure

=cut

sub _processAptPreferences
{
	my $self = $_[0];

	my $fileContent = '';

	for(@{$self->{'aptPreferences'}}) {
		unless(exists $_->{'pinning_pin'} || exists $_->{'pinning_pin_priority'}) {
			error('One of these attributes is missing: pinning_pin or pinning_pin_priority');
			return 1;
		}

		$fileContent .= "Package: $_->{'pinning_package'}\n";
		$fileContent .= "Pin: $_->{'pinning_pin'}\n";
		$fileContent .= "Pin-Priority: $_->{'pinning_pin_priority'}\n\n";
	}

	my $file = iMSCP::File->new( filename => '/etc/apt/preferences.d/imscp' );

	if($fileContent ne '') {
		my $rs = $file->set($fileContent);
		$rs ||= $file->save();
		$rs ||= $file->mode(0644);
		return $rs if $rs;
	} elsif(-f '/etc/apt/preferences.d/imscp') {
		my $rs = $file->delFile();
		return $rs if $rs;
	}

	0;
}

=item _prefillDebconfDatabase()

 Pre-fill debconf database

 Return int 0 on success, other on failure

=cut

sub _prefillDebconfDatabase
{
	my $self = $_[0];

	my $sqlServer = $main::questions{'SQL_SERVER'} || undef;
	my $poServer = $main::questions{'PO_SERVER'} || undef;
	my $sqlServerPackageName = undef;

	if(defined $sqlServer) {
		if($sqlServer ne 'remote_server') {
			if($sqlServer =~ /^(mysql|mariadb|percona)_(\d+\.\d+)$/) {
				$sqlServerPackageName = "$1-server" . ($1 eq 'percona' ? '-server' : '') . "-$2";
			} else {
				error("Unknown SQL server package name: $sqlServer");
				return 1;
			}
		}
	} else {
		error('Unable to retrieve SQL server name');
		return 1;
	}

	# Most values below are not really important because i-MSCP will override them after package installation
	my $mailname = `hostname --fqdn 2>/dev/null` || 'localdomain';
	chomp $mailname;

	my $hostname = ($mailname ne 'localdomain') ? $mailname : 'localhost';

	my $domain = `hostname --domain 2>/dev/null` || 'localdomain';
	chomp $domain;

	# From postfix package postfix.config script
	my $destinations;
	if ($mailname eq $hostname) {
		$destinations = join ', ', ($mailname, 'localhost.' . $domain, ', localhost');
	} else {
		$destinations = join ', ', ($mailname, $hostname, 'localhost.' . $domain . ', localhost');
	}

	my $selectionsFileContent = <<EOF;
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string $mailname
postfix postfix/destinations string $destinations
proftpd-basic shared/proftpd/inetd_or_standalone select standalone
EOF

	if(defined $poServer) {
		if($poServer eq 'courier') {
			$selectionsFileContent .= <<EOF;
courier-base courier-base/webadmin-configmode boolean false
courier-ssl courier-ssl/certnotice note
EOF
		} elsif($poServer eq 'dovecot') {
	$selectionsFileContent .= <<EOF;
dovecot-core dovecot-core/create-ssl-cert boolean true
dovecot-core dovecot-core/ssl-cert-name string localhost
EOF
		}
	} else {
		error('Unable to retrieve PO server name');
		return 1;
	}

	if(iMSCP::Getopt->preseed && $sqlServer ne 'remote_server') {
		$selectionsFileContent .= <<EOF;
$sqlServerPackageName mysql-server/root_password password $main::questions{'DATABASE_PASSWORD'}
$sqlServerPackageName mysql-server/root_password_again password $main::questions{'DATABASE_PASSWORD'}
EOF
	}

	my $debconfSelectionsFile = File::Temp->new();
	print $debconfSelectionsFile $selectionsFileContent;

	my ($stdout, $stderr);
	my $rs = execute("debconf-set-selections $debconfSelectionsFile", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $rs && $stderr;
	error('Unable to pre-fill debconf database') if $rs && ! $stderr;

	$rs;
}

=back

=head1 AUTHORS

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
