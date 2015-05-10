=head1 NAME

 Servers::httpd::apache_fcgid::installer - i-MSCP Apache2/FastCGI Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2015 by internet Multi Server Control Panel
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

package Servers::httpd::apache_fcgid::installer;

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use iMSCP::Debug;
use iMSCP::EventManager;
use iMSCP::Config;
use iMSCP::Execute;
use iMSCP::Rights;
use iMSCP::SystemGroup;
use iMSCP::SystemUser;
use iMSCP::Dir;
use iMSCP::File;
use iMSCP::TemplateParser;
use iMSCP::ProgramFinder;
use File::Basename;
use Servers::httpd::apache_fcgid;
use version;
use Net::LibIDN qw/idn_to_ascii/;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Installer for the i-MSCP Apache2/FastCGI Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
	my ($self, $eventManager) = @_;

	my $rs = $eventManager->register('beforeSetupDialog', sub { push @{$_[0]}, sub { $self->showDialog(@_) }; 0; });
	return $rs if $rs;

	# Fix error_reporting value into the database
	$eventManager->register('afterSetupCreateDatabase', sub { $self->_fixPhpErrorReportingValues(@_) });
}

=item showDialog(\%dialog)

 Show dialog

 Param iMSCP::Dialog \%dialog
 Return int 0 on success, other on failure

=cut

sub showDialog
{
	my ($self, $dialog) = @_;

	my $rs = 0;
	my $phpiniLevel = main::setupGetQuestion('INI_LEVEL') || $self->{'config'}->{'INI_LEVEL'};

	if(
		$main::reconfigure ~~ ['httpd', 'php', 'servers', 'all', 'forced'] ||
		not $phpiniLevel ~~ ['per_user', 'per_domain', 'per_site']
	) {
		$phpiniLevel =~ s/_/ /;

		($rs, $phpiniLevel) = $dialog->radiolist(
"
\\Z4\\Zb\\ZuPHP INI Level\\Zn

Please, choose the PHP INI level you want use for PHP. Available levels are:

\\Z4Per user:\\Zn Each customer will have only one php.ini file
\\Z4Per domain:\\Zn Each domain / domain alias will have its own php.ini file
\\Z4Per site:\\Zn Each site will have its own php.ini file

",
			['per user', 'per domain', 'per site'],
			$phpiniLevel ne 'per site' && $phpiniLevel ne 'per domain' ? 'per user' : $phpiniLevel
		);
	}

	($self->{'config'}->{'INI_LEVEL'} = $phpiniLevel) =~ s/ /_/ unless $rs == 30;

	$rs;
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdInstall', 'apache_fcgid');
	return $rs if $rs;

	# Saving all system configuration files if they exists
	for ("$main::imscpConfig{'LOGROTATE_CONF_DIR'}/apache2", "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf") {
		$rs = $self->_bkpConfFile($_);
		return $rs if $rs;
	}

	$rs = $self->_setApacheVersion();
	return $rs if $rs;

	$rs = $self->_makeDirs();
	return $rs if $rs;

	$rs = $self->_buildFastCgiConfFiles();
	return $rs if $rs;

	$rs = $self->_buildApacheConfFiles();
	return $rs if $rs;

	$rs = $self->_installLogrotate();
	return $rs if $rs;

	$rs = $self->_setupVlogger();
	return $rs if $rs;

	$rs = $self->_saveConf();
	return $rs if $rs;

	$rs = $self->_oldEngineCompatibility();
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdInstall', 'apache_fcgid');
}

=item setEnginePermissions

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
	my $self = $_[0];

	my $rootUName = $main::imscpConfig{'ROOT_USER'};
	my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
	my $fcgiDir = $self->{'config'}->{'PHP_STARTER_DIR'};

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdSetEnginePermissions');
	return $rs if $rs;

	$rs = setRights($fcgiDir, { 'user' => $rootUName, 'group' => $rootGName, mode => '0555' });
	return $rs if $rs;

	$rs = setRights('/usr/local/sbin/vlogger', { 'user' => $rootUName, 'group' => $rootGName, mode => '0750' });
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdSetEnginePermissions');
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::httpd::apache_fcgid::installer

=cut

sub _init
{
	my $self = $_[0];

	$self->{'eventManager'} = iMSCP::EventManager->getInstance();

	$self->{'httpd'} = Servers::httpd::apache_fcgid->getInstance();

	$self->{'eventManager'}->trigger(
		'beforeHttpdInitInstaller', $self, 'apache_fcgid'
	) and fatal('apache_fcgid - beforeHttpdInitInstaller has failed');

	$self->{'apacheCfgDir'} = $self->{'httpd'}->{'apacheCfgDir'};
	$self->{'apacheBkpDir'} = "$self->{'apacheCfgDir'}/backup";
	$self->{'apacheWrkDir'} = "$self->{'apacheCfgDir'}/working";

	$self->{'config'} = $self->{'httpd'}->{'config'};

	# Merge old config file with new config file
	my $oldConf = "$self->{'apacheCfgDir'}/apache.old.data";
	if(-f $oldConf) {
		tie my %oldConfig, 'iMSCP::Config', fileName => $oldConf;

		for(keys %oldConfig) {
			if(exists $self->{'config'}->{$_}) {
				$self->{'config'}->{$_} = $oldConfig{$_};
			}
		}
	}

	$self->{'eventManager'}->trigger(
		'afterHttpdInitInstaller', $self, 'apache_fcgid'
	) and fatal('apache_fcgid - afterHttpdInitInstaller has failed');

	$self;
}

=item _bkpConfFile($cfgFile)

 Backup the given file

 Param string $cfgFile File to backup
 Return int 0 on success, other on failure

=cut

sub _bkpConfFile
{
	my ($self, $cfgFile) = @_;

	my $timestamp = time;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdBkpConfFile', $cfgFile);
	return $rs if $rs;

	if(-f $cfgFile){
		my $file = iMSCP::File->new('filename' => $cfgFile);
		my $filename = fileparse($cfgFile);

		if(! -f "$self->{'apacheBkpDir'}/$filename.system") {
			$rs = $file->copyFile("$self->{'apacheBkpDir'}/$filename.system");
			return $rs if $rs;
		} else {
			$rs = $file->copyFile("$self->{'apacheBkpDir'}/$filename.$timestamp");
			return $rs if $rs;
		}
	}

	$self->{'eventManager'}->trigger('afterHttpdBkpConfFile', $cfgFile);
}

=item _setApacheVersion()

 Set Apache version

 Return in 0 on success, other on failure

=cut

sub _setApacheVersion
{
	my $self = $_[0];

	my ($stdout, $stderr);
	my $rs = execute('apache2ctl -v', \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	error('Unable to find Apache version') if $rs && ! $stderr;
	return $rs if $rs;

	if($stdout =~ m%Apache/([\d.]+)%) {
		$self->{'config'}->{'HTTPD_VERSION'} = $1;
		debug("Apache version set to: $1");
	} else {
		error('Unable to parse Apache version from Apache version string');
		return 1;
	}

	0;
}

=item _makeDirs()

 Create directories

 Return int 0 on success, other on failure

=cut

sub _makeDirs
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdMakeDirs');
	return $rs if $rs;

	my $rootUName = $main::imscpConfig{'ROOT_USER'};
	my $rootGName = $main::imscpConfig{'ROOT_GROUP'};
	my $phpdir = $self->{'config'}->{'PHP_STARTER_DIR'};

	# Remove any older fcgi directory ( prevent possible orphaned file when switching to another ini level )
	$rs = iMSCP::Dir->new('dirname' => $self->{'config'}->{'PHP_STARTER_DIR'})->remove();
	return $rs if $rs;

	for (
		[ $self->{'config'}->{'HTTPD_LOG_DIR'}, $rootUName, $rootUName, 0755 ],
		[ $phpdir, $rootUName, $rootGName, 0555 ],
	) {
		$rs = iMSCP::Dir->new('dirname' => $_->[0])->make({ 'user' => $_->[1], 'group' => $_->[2], 'mode' => $_->[3]});
		return $rs if $rs;
	}

	$self->{'eventManager'}->trigger('afterHttpdMakeDirs');
}

=item _buildFastCgiConfFiles()

 Build FastCGI configuration files

 Return int 0 on success, other on failure

=cut

sub _buildFastCgiConfFiles
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdBuildFastCgiConfFiles');

	# Save current production files if any
	for ('fcgid_imscp.conf', 'fcgid_imscp.load') {
		$rs = $self->_bkpConfFile("$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/$_");
		return $rs if $rs;
	}

	# Build, store and install new files

	my $version = $self->{'config'}->{'HTTPD_VERSION'};
	my $apache24 = (version->parse($version) >= version->parse('2.4.0'));

	# Set needed data
	$self->{'httpd'}->setData(
		{
			SYSTEM_USER_PREFIX => $main::imscpConfig{'SYSTEM_USER_PREFIX'},
			SYSTEM_USER_MIN_UID => $main::imscpConfig{'SYSTEM_USER_MIN_UID'},
			PHP_STARTER_DIR => $self->{'config'}->{'PHP_STARTER_DIR'},
			AUTHZ_ALLOW_ALL => ($apache24) ? 'Require all granted' : 'Allow from all'
		}
	);

	# fcgid_imscp.conf

	$rs = $self->{'httpd'}->buildConfFile("$self->{'apacheCfgDir'}/fcgid_imscp.conf");
	return $rs if $rs;

	my $file = iMSCP::File->new('filename' => "$self->{'apacheWrkDir'}/fcgid_imscp.conf");

	$rs = $file->copyFile($self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'});
	return $rs if $rs;

	# Load system configuration file
	$file = iMSCP::File->new('filename' => "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/fcgid.load");

	my $cfgTpl = $file->get();
	unless(defined $cfgTpl) {
		error("Unable to read $file->{'filename'}");
		return 1;
	}

	# Build new configuration file and store it in working directory
	$file = iMSCP::File->new('filename' => "$self->{'apacheWrkDir'}/fcgid_imscp.load");

	$cfgTpl = "<IfModule !mod_fcgid.c>\n" . $cfgTpl . "</IfModule>\n";

	$rs = $file->set($cfgTpl);
	return $rs if $rs;

	# Store new file
	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0644);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $main::imscpConfig{'ROOT_GROUP'});
	return $rs if $rs;

	# Install new file in production directory
	$rs = $file->copyFile($self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'});
	return $rs if $rs;

	# Disable/Enable Apache modules

	# # Transitional: fastcgi_imscp
	my @toDisableModules = (
		'fastcgi', 'fcgid', 'php4', 'php5', 'php5_cgi', 'php5filter', 'php_fpm_imscp', 'fastcgi_imscp'
	);

	my @toEnableModules = ('actions', 'fcgid_imscp',);

	if(version->parse($version) >= version->parse('2.4.0')) {
		push (@toDisableModules, ('mpm_event', 'mpm_itk', 'mpm_prefork'));
		push (@toEnableModules, 'mpm_worker', 'authz_groupfile');
	}

	for(@toDisableModules) {
		$rs = $self->{'httpd'}->disableModules($_) if -l "$self->{'config'}->{'HTTPD_MODS_ENABLED_DIR'}/$_.load";
		return $rs if $rs;
	}

	for(@toEnableModules) {
		$rs = $self->{'httpd'}->enableModules($_) if -f "$self->{'config'}->{'HTTPD_MODS_AVAILABLE_DIR'}/$_.load";
		return $rs if $rs;
	}

	# Make sure that PHP modules are enabled
	if(iMSCP::ProgramFinder::find('php5enmod')) {
		for (
			'apc', 'curl', 'gd', 'imap', 'intl', 'json', 'mcrypt', 'mysqlnd/10', 'mysqli', 'mysql', 'opcache', 'pdo/10',
			'pdo_mysql'
		) {
			my($stdout, $stderr);
			$rs = execute("php5enmod $_", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			unless($rs ~~ [0, 2]) {
				error($stderr) if $stderr;
				return $rs;
			}
		}
	}

	$self->{'eventManager'}->trigger('afterHttpdBuildFastCgiConfFiles');
}

=item _buildApacheConfFiles()

 Build Apache configuration files

 Return int 0 on success, other on failure

=cut

sub _buildApacheConfFiles
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdBuildApacheConfFiles');
	return $rs if $rs;

	if(-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf") {
		# Load template

		my $cfgTpl;
		$rs = $self->{'eventManager'}->trigger('onLoadTemplate', 'apache_fcgid', 'ports.conf', \$cfgTpl, { });
		return $rs if $rs;

		unless(defined $cfgTpl) {
			$cfgTpl = iMSCP::File->new('filename' => "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf")->get();
			unless(defined $cfgTpl) {
				error("Unable to read $self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf");
				return 1;
			}
		}

		# Build file

		$rs = $self->{'eventManager'}->trigger('beforeHttpdBuildConfFile', \$cfgTpl, 'ports.conf');
		return $rs if $rs;

		$cfgTpl =~ s/^(NameVirtualHost\s+\*:80)/#$1/gmi;

		$rs = $self->{'eventManager'}->trigger('afterHttpdBuildConfFile', \$cfgTpl, 'ports.conf');
		return $rs if $rs;

		# Store file

		my $file = iMSCP::File->new('filename' => "$self->{'config'}->{'HTTPD_CONF_DIR'}/ports.conf");

		$rs = $file->set($cfgTpl);
		return $rs if $rs;

		$rs = $file->mode(0644);
		return $rs if $rs;

		$rs = $file->save();
		return $rs if $rs;
	}

	# Turn off default access log provided by Debian package
	if(-d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available") {
		$rs = $self->{'httpd'}->disableConfs('other-vhosts-access-log.conf');
		return $rs if $rs;
	} elsif(-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/other-vhosts-access-log") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d/other-vhosts-access-log"
		)->delFile();
		return $rs if $rs;
	}

	# Remove default access log file provided by Debian package
	if(-f "$self->{'config'}->{'HTTPD_LOG_DIR'}/other_vhosts_access.log") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'config'}->{'HTTPD_LOG_DIR'}/other_vhosts_access.log"
		)->delFile();
		return $rs if $rs;
	}

	# Backup, build, store and install 00_nameserver.conf file

	if(-f "$self->{'apacheWrkDir'}/00_nameserver.conf") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'apacheWrkDir'}/00_nameserver.conf"
		)->copyFile("$self->{'apacheBkpDir'}/00_nameserver.conf." . time);
		return $rs if $rs;
	}

	my $version = $self->{'config'}->{'HTTPD_VERSION'};

	# Using alternative syntax for piped logs scripts when possible
	# The alternative syntax does not involve the shell (from Apache 2.2.12)
	my $pipeSyntax = '|';
	if(version->parse($version) >= version->parse('2.2.12')) {
		$pipeSyntax .= '|';
	}

	my $apache24 = (version->parse($version) >= version->parse('2.4.0'));

	# Set needed data
	$self->{'httpd'}->setData(
		{
			HTTPD_LOG_DIR => $self->{'config'}->{'HTTPD_LOG_DIR'},
			HTTPD_ROOT_DIR => $self->{'config'}->{'HTTPD_ROOT_DIR'},
			AUTHZ_DENY_ALL => ($apache24) ? 'Require all denied' : 'Deny from all',
			AUTHZ_ALLOW_ALL => ($apache24) ? 'Require all granted' : 'Allow from all',
			PIPE => $pipeSyntax,
			VLOGGER_CONF => "$self->{'apacheWrkDir'}/vlogger.conf"
		}
	);

	# Build file
	$rs = $self->{'httpd'}->buildConfFile('00_nameserver.conf');
	return $rs if $rs;

	# Install file
	$rs = $self->{'httpd'}->installConfFile('00_nameserver.conf');
	return $rs if $rs;

	# Backup, build, store and install 00_imscp.conf file

	if(-f "$self->{'apacheWrkDir'}/00_imscp.conf") {
		$rs = iMSCP::File->new(
			'filename' => "$self->{'apacheWrkDir'}/00_imscp.conf"
		)->copyFile("$self->{'apacheBkpDir'}/00_imscp.conf." . time);
		return $rs if $rs;
	}

	# Set needed data
	$self->{'httpd'}->setData({ HTTPD_CUSTOM_SITES_DIR => $self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'} });

	# Build file
	$rs = $self->{'httpd'}->buildConfFile('00_imscp.conf');
	return $rs if $rs;

	# Install file
	$rs = $self->{'httpd'}->installConfFile('00_imscp.conf', {
		destination => (-d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available")
			? "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available"
			: "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf.d"
	});
	return $rs if $rs;

	# Enable required apache modules
	$rs = $self->{'httpd'}->enableModules('cgid proxy proxy_http rewrite ssl suexec');
	return $rs if $rs;

	# Enbale 00_nameserver.conf file
	$rs = $self->{'httpd'}->enableSites('00_nameserver.conf');
	return $rs if $rs;

	# Enbale 00_imscp.conf file
	$rs = $self->{'httpd'}->enableConfs('00_imscp.conf');
	return $rs if $rs;

	# Disable defaults sites if any
	#
	# default, default-ssl (Debian < Jessie)
	# 000-default.conf, default-ssl.conf' : (Debian >= Jessie)
	for('default', 'default-ssl', '000-default.conf', 'default-ssl.conf') {
		$rs = $self->{'httpd'}->disableSites($_) if -f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_";
		return $rs if $rs;
	}

	$self->{'eventManager'}->trigger('afterHttpdBuildApacheConfFiles');
}

=item _installLogrotate()

 Install Apache logrotate file

 Return int 0 on success, other on failure

=cut

sub _installLogrotate
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdInstallLogrotate', 'apache2');
	return $rs if $rs;

	$rs = $self->{'httpd'}->buildConfFile('logrotate.conf');
	return $rs if $rs;

	$rs = $self->{'httpd'}->installConfFile(
		'logrotate.conf', { 'destination' => "$main::imscpConfig{'LOGROTATE_CONF_DIR'}/apache2" }
	);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdInstallLogrotate', 'apache2');
}

=item _setupVlogger()

 Setup vlogger

 Return int 0 on success, other on failure

=cut

sub _setupVlogger
{
	my $self = $_[0];

	my $dbHost = main::setupGetQuestion('DATABASE_HOST');
	# vlogger is chrooted so we force connection to MySQL server through TCP
	$dbHost = ($dbHost eq 'localhost') ? '127.0.0.1' : $dbHost;
	my $dbPort = main::setupGetQuestion('DATABASE_PORT');
	my $dbName = main::setupGetQuestion('DATABASE_NAME');
	my $tableName = 'httpd_vlogger';
	my $dbUser = 'vlogger_user';
	my $dbUserHost = main::setupGetQuestion('DATABASE_USER_HOST');
	$dbUserHost = ($dbUserHost eq '127.0.0.1') ? 'localhost' : $dbUserHost;

	my @allowedChr = map { chr } (0x21..0x5b, 0x5d..0x7e);
	my $dbPassword = '';
	$dbPassword .= $allowedChr[rand @allowedChr] for 1..16;

	# Getting SQL connection with full privileges
	my ($db, $errStr) = main::setupGetSqlConnect($dbName);
	fatal("Unable to connect to SQL server: $errStr") unless $db;

	# Creating database table
	if(-f "$self->{'apacheCfgDir'}/vlogger.sql") {
		my $rs = main::setupImportSqlSchema($db, "$self->{'apacheCfgDir'}/vlogger.sql");
		return $rs if $rs;
	} else {
		error("File $self->{'apacheCfgDir'}/vlogger.sql not found.");
		return 1;
	}

	# Removing any old SQL user (including privileges)
	for my $host($dbUserHost, $main::imscpOldConfig{'DATABASE_USER_HOST'}, '127.0.0.1') {
		next unless $host;

		if(main::setupDeleteSqlUser($dbUser, $host)) {
			error('Unable to remove SQL user or one of its privileges');
			return 1;
		}
	}

	my @dbUserHosts = ($dbUserHost);

	if($dbUserHost ~~ ['localhost', '127.0.0.1']) {
		push @dbUserHosts, ($dbUserHost eq '127.0.0.1') ? 'localhost' : '127.0.0.1';
	}

	for(@dbUserHosts) {
		# Adding new SQL user with needed privileges
		my $rs = $db->doQuery(
			'dummy',
			"GRANT SELECT, INSERT, UPDATE ON `$main::imscpConfig{'DATABASE_NAME'}`.`$tableName` TO ?@? IDENTIFIED BY ?",
			$dbUser,
			$_,
			$dbPassword
		);
		unless(ref $rs eq 'HASH') {
			error("Unable to add privileges: $rs");
			return 1;
		}
	}

	# Building configuration file
	$self->{'httpd'}->setData(
		{
			DATABASE_NAME => $dbName,
			DATABASE_HOST => $dbHost,
			DATABASE_PORT => $dbPort,
			DATABASE_USER => $dbUser,
			DATABASE_PASSWORD => $dbPassword
		}
	);
	$self->{'httpd'}->buildConfFile(
		"$self->{'apacheCfgDir'}/vlogger.conf.tpl", { }, { 'destination' => "$self->{'apacheWrkDir'}/vlogger.conf" }
	);
}

=item _saveConf()

 Save configuration

 Return int 0 on success, other on failure

=cut

sub _saveConf
{
	my $self = $_[0];

	iMSCP::File->new(
		'filename' => "$self->{'apacheCfgDir'}/apache.data"
	)->copyFile(
		"$self->{'apacheCfgDir'}/apache.old.data"
	);
}

=item _oldEngineCompatibility()

 Remove old files

 Return int 0 on success, other on failure

=cut

sub _oldEngineCompatibility
{
	my $self = $_[0];

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdOldEngineCompatibility');
	return $rs if $rs;

	for('imscp.conf', '00_modcband.conf', '00_master.conf', '00_master_ssl.conf') {
		if(-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_") {
			$rs = $self->{'httpd'}->disableSites($_);
			return $rs if $rs;

			$rs = iMSCP::File->new('filename' => "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$_")->delFile();
			return $rs if $rs;
		}
	}

	# Remove deprecated php5-fastcgi-starter files if any
	if(-d $self->{'config'}->{'PHP_STARTER_DIR'}) {
		my ($stdout, $stderr);
		$rs = execute("rm -f $self->{'config'}->{'PHP_STARTER_DIR'}/*/php5-fastcgi-starter", \$stdout, \$stderr);
		return $rs if $rs;
	}

	# Remove directories no longer needed (since 1.1.0)
	for(
		$self->{'config'}->{'APACHE_BACKUP_LOG_DIR'}, $self->{'config'}->{'HTTPD_USERS_LOG_DIR'},
		$self->{'config'}->{'APACHE_SCOREBOARDS_DIR'}
	) {
		$rs = iMSCP::Dir->new('dirname' => $_)->remove();
		return $rs if $rs;
	}

	$self->{'eventManager'}->trigger('afterHttpdOldEngineCompatibility');
}

=item _fixPhpErrorReportingValues()

 Fix PHP error reporting values according current PHP version

 Return int 0 on success, other on failure

=cut

sub _fixPhpErrorReportingValues
{
	my $self = $_[0];

	my ($database, $errStr) = main::setupGetSqlConnect($main::imscpConfig{'DATABASE_NAME'});
	unless($database) {
		error("Unable to connect to SQL server: $errStr");
		return 1;
	}

	my ($stdout, $stderr);
	my $rs = execute('php -v', \$stdout, \$stderr);
	debug($stdout) if $stdout;
	debug($stderr) if $stderr && ! $rs;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	my $phpVersion = $1 if $stdout =~ /^PHP\s([\d.]{3})/;

	if(defined $phpVersion) {
		if($phpVersion == 5.3) {
			$phpVersion = 5.3;
		} elsif($phpVersion >= 5.4) {
			$phpVersion = 5.4
		} else {
			error("Unsupported PHP version: $phpVersion");
			return 1;
		}
	} else {
		error('Unable to find PHP version');
		return 1;
	}

	my %errorReportingValues = (
		'5.3' => {
			32759 => 30711, # E_ALL & ~E_NOTICE
			32767 => 32767, # E_ALL | E_STRICT
			24575 => 22527  # E_ALL & ~E_DEPRECATED
		},
		'5.4' => {
			30711 => 32759, # E_ALL & ~E_NOTICE
			32767 => 32767, # E_ALL | E_STRICT
			22527 => 24575  # E_ALL & ~E_DEPRECATED
		}
	);

	for(keys %{$errorReportingValues{$phpVersion}}) {
		my $from = $_;
		my $to = $errorReportingValues{$phpVersion}->{$_};

		$rs = $database->doQuery(
			'dummy',
			"UPDATE `config` SET `value` = ? WHERE `name` = 'PHPINI_ERROR_REPORTING' AND `value` = ?",
			$to, $from
		);
		unless(ref $rs eq 'HASH') {
			error($rs);
			return 1;
		}

		$rs = $database->doQuery(
			'dummy', 'UPDATE `php_ini` SET `error_reporting` = ? WHERE `error_reporting` = ?', $to, $from
		);
		unless(ref $rs eq 'HASH') {
			error($rs);
			return 1;
		}
	}

	0;
}

=back

=head1 AUTHORS

 Daniel Andreca <sci2tech@gmail.com>
 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
