=head1 NAME

 iMSCP::PkgManager - High-level interface for package manager providers

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

package iMSCP::PkgManager;

use strict;
use warnings;
use iMSCP::LsbRelease;
use Module::Load::Conditional qw/can_load/;
use parent 'Common::SingletonClass';

$Module::Load::Conditional::FIND_VERSION = 0;

=head1 DESCRIPTION

 High-level interface for package manager providers.

=head1 PUBLIC METHODS

=over 4

=item getProvider()

 Get package manager provider instance

 Return iMSCP::Provider::PkgManager::Abstract or die on failure

=cut

sub getProvider
{
	my $self = shift;

	unless($self->{'provider'}) {
		my $provider = "iMSCP::Provider::PkgManager::" . iMSCP::LsbRelease->getInstance->getId('short');

		can_load(modules => { $provider => undef }) or die(
			sprintf("Unable to load %s: %s", $provider, $Module::Load::Conditional::ERROR)
		);

		$self->{'provider'} = $provider->getInstance();
	}

	$self->{'provider'};
}

=item AUTOLOAD()

 Proxy to package manager provider methods

 Return mixed

=cut

sub AUTOLOAD
{
	my $self = shift;

	(my $method = our $AUTOLOAD) =~ s/.*:://;

	$self->getProvider()->$method(@_);
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
