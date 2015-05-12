=head1 NAME

Package::AntiRootkits - i-MSCP Anti-Rootkits package

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

package Package::AntiRootkits;

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::PkgManager;
use iMSCP::ProgramFinder;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Anti-Rootkits package.

 Wrapper that handles all available Anti-Rootkits packages found in the AntiRootkits directory.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
	my ($self, $eventManager) = @_;

	$eventManager->register('beforeSetupDialog', sub { push @{$_[0]}, sub { $self->showDialog(@_) }; 0; });
}

=item askAntiRootkits(\%dialog)

 Show dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 or 30

=cut

sub showDialog
{
	my ($self, $dialog) = @_;

	my $packages = [ split ',', main::setupGetQuestion('ANTI_ROOTKITS_PACKAGES') ];
	my $rs = 0;

	if(
		$main::reconfigure ~~ [ 'antirootkits', 'all', 'forced' ] || ! @{$packages} ||
		grep { not $_ ~~ [ $self->{'PACKAGES'}, 'No' ] } @{$packages}
	) {
		($rs, $packages) = $dialog->checkbox(
			"\nPlease select the Anti-Rootkits packages you want to install:",
			[ @{$self->{'PACKAGES'}} ],
			(@{$packages} ~~ 'No') ? () : (@{$packages} ? @{$packages} : @{$self->{'PACKAGES'}})
		);
	}

	if($rs != 30) {
		main::setupSetQuestion('ANTI_ROOTKITS_PACKAGES', @{$packages} ? join ',', @{$packages} : 'No');

		if(not 'No' ~~ @{$packages}) {
			for(@{$packages}) {
				my $package = "Package::AntiRootkits::${_}::${_}";
				eval "require $package";

				unless($@) {
					$package = $package->getInstance();

					if($package->can('showDialog')) {
						debug(sprintf('Calling action showDialog on %s', ref $package));
						$rs = $package->showDialog($dialog);
						return $rs if $rs;
					}
				} else {
					error($@);
					return 1;
				}
			}
		}
	}

	$rs;
}

=item preinstall()

 Process preinstall tasks

 /!\ This method also trigger uninstallation of unselected Anti-Rootkits packages.

 Return int 0 on success, other on failure

=cut

sub preinstall
{
	my $self = $_[0];

	my $rs = 0;
	my @packages = split ',', main::setupGetQuestion('ANTI_ROOTKITS_PACKAGES');
	my $packagesToInstall = [ grep { $_ ne 'No'} @packages ];
	my $packagesToUninstall = [ grep { not $_ ~~  @{$packagesToInstall}} @{$self->{'PACKAGES'}} ];

	if(@{$packagesToUninstall}) {
		my $packages = [];

		for(@{$packagesToUninstall}) {
			my $package = "Package::AntiRootkits::${_}::${_}";
			eval "require $package";

			unless($@) {
				$package = $package->getInstance();

				if($package->can('uninstall')) {
					debug(sprintf('Calling action uninstall on %s', ref $package));
					$rs = $package->uninstall();
					return $rs if $rs;
				}

				if($package->can('getDistroPackages')) {
					debug(sprintf('Calling action getDistroPackages on %s', ref $package));
					@{$packages} = (@{$packages}, @{$package->getDistroPackages()});
				}
			} else {
				error($@);
				return 1;
			}
		}

		if(defined $main::skippackages && !$main::skippackages && @{$packages}) {
			$rs = $self->_removePackages($packages);
			return $rs if $rs;
		}
	}

	if(@{$packagesToInstall}) {
		my $packages = [];

		for(@{$packagesToInstall}) {
			my $package = "Package::AntiRootkits::${_}::${_}";
			eval "require $package";

			unless($@) {
				$package = $package->getInstance();

				if($package->can('preinstall')) {
					debug(sprintf('Calling action preinstall on %s', ref $package));
					$rs = $package->preinstall();
					return $rs if $rs;
				}

				if($package->can('getDistroPackages')) {
					debug(sprintf('Calling action getDistroPackages on %s', ref $package));
					@{$packages} = (@{$packages}, @{$package->getDistroPackages()});
				}
			} else {
				error($@);
				return 1;
			}
		}

		if(defined $main::skippackages && !$main::skippackages && @{$packages}) {
			$rs = $self->_installPackages($packages);
			return $rs if $rs;
		}
	}

	$rs;
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
	my @packages = split ',', main::setupGetQuestion('ANTI_ROOTKITS_PACKAGES');

	if(not 'No' ~~ @packages) {
		for(@packages) {
			my $package = "Package::AntiRootkits::${_}::${_}";
			eval "require $package";

			unless($@) {
				$package = $package->getInstance();

				if($package->can('install')) {
					debug(sprintf('Calling action install on %s', ref $package));
					my $rs = $package->install();
					return $rs if $rs;
				}
			} else {
				error($@);
				return 1;
			}
		}
	}

	0;
}

=item uninstall()

 Process uninstall tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
	my $self = $_[0];

	my @packages = split ',', $main::imscpConfig{'ANTI_ROOTKITS_PACKAGES'};

	my $packages = [];
	my $rs = 0;

	for(@packages) {
		if($_ ~~ @{$self->{'PACKAGES'}}) {
			my $package = "Package::AntiRootkits::${_}::${_}";
			eval "require $package";

			unless($@) {
				$package = $package->getInstance();

				if($package->can('uninstall')) {
					debug(sprintf('Calling action uninstall on %s', ref $package));
					$rs = $package->uninstall();
					return $rs if $rs;
				}

				if($package->can('getDistroPackages')) {
					debug(sprintf('Calling action getDistroPackages on %s', ref $package));
					@{$packages} = (@{$packages}, @{$package->getDistroPackages()});
				}
			} else {
				error($@);
				return 1;
			}
		}
	}

	if(defined $main::skippackages && !$main::skippackages && @{$packages}) {
		$rs = $self->_removePackages($packages);
	}

	$rs;
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
	my $self = $_[0];

	my @packages = split ',', $main::imscpConfig{'ANTI_ROOTKITS_PACKAGES'};

	for(@packages) {
		if($_ ~~ @{$self->{'PACKAGES'}}) {
			my $package = "Package::AntiRootkits::${_}::${_}";
			eval "require $package";

			unless($@) {
				$package = $package->getInstance();

				if($package->can('setEnginePermissions')) {
					debug(sprintf('Calling action setEnginePermissions on %s', ref $package));
					my $rs = $package->setEnginePermissions();
					return $rs if $rs;
				}
			} else {
				error($@);
				return 1;
			}
		}
	}

	0;
}

=back

=head1 PRIVATE METHODS

=over 4

=item init()

 Initialize instance

 Return Package::AntiRootkits

=cut

sub _init()
{
	my $self = $_[0];

	# Find list of available AntiRootkits packages
	@{$self->{'PACKAGES'}} = iMSCP::Dir->new(
		dirname => "$main::imscpConfig{'ENGINE_ROOT_DIR'}/PerlLib/Package/AntiRootkits"
	)->getDirs();

	$self;
}

=item _installPackages(\@packages)

 Install packages

 Param array \@packages List of packages to install
 Return int 0 on success, other on failure

=cut

sub _installPackages
{
	my ($self, $packages) = @_;

	iMSCP::PkgManager->getInstance()->installPackages(@{$packages});
}

=item _removePackages(\@packages)

 Remove packages

 Param array \@packages List of packages to remove
 Return int 0 on success, other on failure

=cut

sub _removePackages
{
	my ($self, $packages) = @_;

	iMSCP::PkgManager->getInstance()->uninstallPackages(@{$packages});
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
