=head1 NAME

 iMSCP::PkgManager - openSUSE packages manager provider

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

package iMSCP::Provider::PkgManager::openSUSE;

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use iMSCP::Debug;
use iMSCP::Dialog;
use iMSCP::Execute;
use iMSCP::Getopt;
use iMSCP::ProgramFinder;
use parent 'iMSCP::Provider::PkgManager::Abstract';

=head1 DESCRIPTION

 Debian packages manager provider.

=head1 PUBLIC METHODS

=over 4

=item updateIndex()

 Update index of packages

 Return 0 on success, other on failure

=cut

sub updateIndex
{
	my $self = shift;

	iMSCP::Dialog->getInstance()->endGauge() if iMSCP::ProgramFinder::find('dialog');

	my $preseed = iMSCP::Getopt->preseed;

	my ($stdout, $stderr);
	my $rs = execute("zyppper refresh", ($preseed || $main::noprompt) ? \$stdout : undef, \$stderr);
	error($stderr) if $stderr && $rs;
	error('Unable to update package index from remote repository') if $rs && ! $stderr;

	$rs
}

=item installPackages(@packages)

 Install the given list of packages

 Param list @packages List of package to install
 Return 0 on success, other on failure

=cut

sub installPackages
{
	my ($self, @packages) = @_;

	if(@packages) {
		iMSCP::Dialog->getInstance()->endGauge() if iMSCP::ProgramFinder::find('dialog');

		my $preseed = iMSCP::Getopt->preseed;
		my @command = (
			'zypper', '--quiet', '--terse', '--non-interactive', '--gpg-auto-import-keys', 'install', '--name',
			'--auto-agree-with-licenses', '--no-recommends', '--no-force-resolution', '--download-in-advance',
			@packages
		);

		my ($stdout, $stderr);
		my $rs = execute("@command", ($preseed || $main::noprompt) ? \$stdout : undef, \$stderr);
		error($stderr) if $stderr && $rs;
		error('Unable to install packages') if $rs && ! $stderr;
		return $rs if $rs;
	}

	0;
}

=item uninstallPackages(@packages)

 Uninstall the given list of packages

 Param list @packages List of package to uninstall
 Return 0 on success, other on failure

=cut

sub uninstallPackages
{
	my ($self, @packages) = @_;

	if(@packages) {
		iMSCP::Dialog->getInstance()->endGauge() if iMSCP::ProgramFinder::find('dialog');

		# Do not try to remove packages which are not installed
		my ($stdout, $stderr);
		my $rs = execute("LANG=C rpm -qa --qf '%{NAME}\n'", \$stdout, \$stderr);
		error($stderr) if $stderr && $rs;
		return $rs if $rs;

		@installedPackages = split /\n/, $stdout;
		@packages = grep { $_ ~~ @installedPackages } @packages;

		if(@packages) {
			my ($stdout, $stderr);
			my $rs = execute(
				"zypper remove --no-force-resolution --clean-deps  @packages",
				(iMSCP::Getopt->preseed || $main::noprompt) ? \$stdout : undef,
				\$stderr
			);
			error($stderr) if $stderr && $rs;
			error('Unable to uninstall packages') if $rs && ! $stderr;
			return $rs if $rs;
		}
	}

	0;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
