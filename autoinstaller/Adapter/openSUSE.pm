=head1 NAME

 autoinstaller::Adapter::openSUSE - openSUSE autoinstaller adapter class

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

package autoinstaller::Adapter::openSUSE;

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use iMSCP::Debug;
use iMSCP::EventManager;
use iMSCP::Execute;
use iMSCP::Dialog;
use iMSCP::File;
use iMSCP::Stepper;
use iMSCP::Getopt;
use iMSCP::ProgramFinder;
use File::Temp;
use parent 'autoinstaller::Adapter::Abstract';

=head1 DESCRIPTION

 i-MSCP autoinstaller adapter implementation for Debian.

=head1 PUBLIC METHODS

=over 4

=back

=head1 AUTHORS

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
