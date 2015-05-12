=head1 NAME

 iMSCP::PkgManager - Abstract packages manager provider

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright 2010-2015 by internet Multi Server Control Panel
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

package iMSCP::Provider::PkgManager::Abstract;

use iMSCP::Debug;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Abstract packages manager provider.

=head1 PUBLIC METHODS

=over 4

=item updateIndex()

 Update index of packages

 Return 0 on success, other on failure

=cut

sub updateIndex
{
	fatal(sprintf('%s must implements the updateIndex() method.', ref shift));
}

=item installPackages(@packages)

 Install the given list of packages

 Param list @packages List of package to install
 Return 0 on success, other on failure

=cut

sub installPackages
{
	fatal(sprintf('%s must implements the updateIndex() method.', ref shift));
}

=item uninstallPackages(@packages)

 Uninstall the given list of packages

 Param list @packages List of package to uninstall
 Return 0 on success, other on failure

=cut

sub uninstallPackages
{
	fatal(sprintf('%s must implements the updateIndex() method.', ref shift));
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
