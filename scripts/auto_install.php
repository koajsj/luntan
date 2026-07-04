#!/usr/bin/env php
<?php

error_reporting(E_ERROR | E_PARSE);
@set_time_limit(0);

define('IN_DISCUZ', true);
define('ROOT_PATH', dirname(__DIR__).'/upload/');
define('INST_LOG_PATH', ROOT_PATH.'data/log/install.log');
define('DISCUZ_DATA', ROOT_PATH.'./data');
define('RUN_MODE', 'install');
define('VIEW_OFF', true);

$_COOKIE['LANG'] = getenv('INSTALL_LANG') ?: 'SC_UTF8';
$_SERVER['HTTP_HOST'] = getenv('SERVER_NAME') && getenv('SERVER_NAME') !== '_' ? getenv('SERVER_NAME') : '127.0.0.1';
$_SERVER['SERVER_NAME'] = $_SERVER['HTTP_HOST'];
$_SERVER['SERVER_ADDR'] = '127.0.0.1';
$_SERVER['SERVER_PORT'] = '80';
$_SERVER['SERVER_SOFTWARE'] = 'discuz-auto-install';
$_SERVER['HTTP_USER_AGENT'] = 'discuz-auto-install';
$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
$_SERVER['PHP_SELF'] = '/install/index.php';

foreach(['data', 'data/log', 'data/cache', 'data/template', 'data/threadcache'] as $dir) {
	if(!is_dir(ROOT_PATH.$dir)) {
		@mkdir(ROOT_PATH.$dir, 0777, true);
	}
}

require ROOT_PATH.'./source/discuz_version.php';
require ROOT_PATH.'./source/mitframe_version.php';
require ROOT_PATH.'./install/include/install_var.php';
require ROOT_PATH.'./install/include/install_mysqli.php';
require ROOT_PATH.'./install/include/install_function.php';
require ROOT_PATH.'./source/class/class_check.php';

set_lang();
require ROOT_PATH.'./source/i18n/'.INSTALL_LANG.'/install/lang_install.php';
timezone_set();

function cli_fail($message) {
	fwrite(STDERR, "[auto-install] ERROR: ".$message.PHP_EOL);
	exit(1);
}

function env_value($name, $default = '') {
	$value = getenv($name);
	return $value === false || $value === '' ? $default : $value;
}

function has_existing_tables($dbhost, $dbuser, $dbpw, $dbname, $tablepre) {
	$link = @new mysqli($dbhost, $dbuser, $dbpw, $dbname);
	if($link->connect_errno) {
		cli_fail('Cannot connect to database: '.$link->connect_error);
	}
	$prefix = $link->real_escape_string($tablepre).'%';
	$query = $link->query("SHOW TABLES LIKE '$prefix'");
	$exists = $query && $query->num_rows > 0;
	$link->close();
	return $exists;
}

function save_cli_ucenter_config($db, $tablepre, $siteurl) {
	$query = $db->query("SELECT appid FROM {$tablepre}ucenter_applications WHERE type='DISCUZX' ORDER BY appid DESC LIMIT 1");
	$appid = $db->result($query, 0);
	$appid = $appid ? $appid : 1;
	$siteurl = rtrim($siteurl, '/');
	$content = <<<PHP
<?php
require __DIR__.'/config_global.php';
define('UC_CONNECT', 'mysql');
define('UC_STANDALONE', 1);
define('UC_DBHOST', \$_config['db'][1]['dbhost']);
define('UC_DBUSER', \$_config['db'][1]['dbuser']);
define('UC_DBPW', \$_config['db'][1]['dbpw']);
define('UC_DBNAME', \$_config['db'][1]['dbname']);
define('UC_DBCHARSET', 'utf8mb4');
define('UC_DBTABLEPRE', '`'.\$_config['db'][1]['dbname'].'`.'.\$_config['db'][1]['tablepre'].'ucenter_');
define('UC_DBCONNECT', '0');
define('UC_AVTURL', '');
define('UC_AVTPATH', '');
define('UC_KEY', \$_config['security']['authkey']);
define('UC_API', '$siteurl');
define('UC_CHARSET', 'utf-8');
define('UC_IP', '127.0.0.1');
define('UC_APPID', '$appid');
define('UC_PPP', '20');
?>
PHP;
	file_put_contents(ROOT_PATH.'./config/config_ucenter.php', $content);
}

global $db, $_config, $serialize_sql_setting, $install_sqlfile;

$lockfile = ROOT_PATH.'./data/install.lock';
if(file_exists($lockfile)) {
	echo "[auto-install] install.lock exists, skipping.".PHP_EOL;
	exit(0);
}

$default_config = [];
include ROOT_PATH.'./config/config_global_default.php';
$default_config = $_config;
include ROOT_PATH.'./config/config_global.php';

$dbhost = env_value('DB_HOST', $_config['db'][1]['dbhost']);
$dbuser = env_value('DB_USER', $_config['db'][1]['dbuser']);
$dbpw = env_value('DB_PASS', $_config['db'][1]['dbpw']);
$dbname = env_value('DB_NAME', $_config['db'][1]['dbname']);
$tablepre = env_value('TABLE_PREFIX', $_config['db'][1]['tablepre']);
$username = env_value('ADMIN_USER', 'admin');
$password = env_value('ADMIN_PASS', 'qwer@1234');
$email = env_value('ADMIN_EMAIL', 'admin@example.com');
$siteurl = env_value('SITE_URL', ($_SERVER['HTTP_HOST'] === '127.0.0.1' ? 'http://127.0.0.1' : 'http://'.$_SERVER['HTTP_HOST']));
$dzucfull = true;
$dzucstl = true;
$myisam2innodb = false;
$uid = 1;

if(!$dbname || !$dbhost) {
	cli_fail('Database configuration is incomplete.');
}
if(strpos($tablepre, '.') !== false || intval($tablepre[0])) {
	cli_fail('Invalid table prefix: '.$tablepre);
}
if(strlen($username) > 15 || preg_match("/^$|^c:\\con\\con$|銆€|[,\"\s\t\<\>&]|^Guest/is", $username)) {
	cli_fail('Invalid admin username.');
}
if(!strstr($email, '@')) {
	cli_fail('Invalid admin email.');
}
if(has_existing_tables($dbhost, $dbuser, $dbpw, $dbname, $tablepre)) {
	cli_fail('Database already contains tables for prefix '.$tablepre.'. Create data/install.lock or use a clean database.');
}

$_config['db'][1]['dbhost'] = $dbhost;
$_config['db'][1]['dbname'] = $dbname;
$_config['db'][1]['dbpw'] = $dbpw;
$_config['db'][1]['dbuser'] = $dbuser;
$_config['db'][1]['dbcharset'] = 'utf8mb4';
$_config['db'][1]['tablepre'] = $tablepre;
$_config['admincp']['founder'] = (string)$uid;
$_config['security']['authkey'] = env_value('AUTHKEY', $_config['security']['authkey'] ?: md5($dbhost.$dbuser.$dbname.$username.time()).secrandom(32));
$_config['cookie']['cookiepre'] = $_config['cookie']['cookiepre'] ?: secrandom(4).'_';
$_config['cookie']['samesite'] = $_config['cookie']['samesite'] ?? 'Lax';
$_config['memory']['prefix'] = $_config['memory']['prefix'] ?: secrandom(6).'_';
$_config['lang'] = INSTALL_LANG;
save_config_file(ROOT_PATH.CONFIG, $_config, $default_config);

$db = new dbstuff;
$db->connect($dbhost, $dbuser, $dbpw, $dbname, DBCHARSET);

install_uc_sql();

$sql = read_sql($install_sqlfile);
runquery($sql);
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('sitevipkey', '".SITEVIP_KEY."')");
rundatasql('lang_'.$install_sqlfile);

$timestamp = time();
$backupdir = substr(md5($_SERVER['SERVER_ADDR'].$_SERVER['HTTP_USER_AGENT'].substr($timestamp, 0, 4)), 8, 6);
if(!is_dir(ROOT_PATH.'data/backup_'.$backupdir)) {
	@mkdir(ROOT_PATH.'data/backup_'.$backupdir, 0777, true);
}
$chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz';
$siteuniqueid = 'DX'.$chars[date('y') % 60].$chars[date('n')].$chars[date('j')].$chars[date('G')].$chars[date('i')].$chars[date('s')].substr(md5($_SERVER['REMOTE_ADDR'].$timestamp), 0, 4).random(4);

$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('authkey', '')");
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('siteuniqueid', '$siteuniqueid')");
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('adminemail', '$email')");
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('backupdir', '$backupdir')");

install_extra_setting();

$localpassword = md5(random(10));
$db->query("REPLACE INTO {$tablepre}common_member (uid, loginname, username, password, adminid, groupid, email, regdate, timeoffset) VALUES ('$uid', '$username', '$username', '$localpassword', '1', '1', '$email', '$timestamp', '9999')");
$db->query("REPLACE INTO {$tablepre}common_member_count SET uid='$uid'");
$db->query("REPLACE INTO {$tablepre}common_member_status SET uid='$uid'");
$db->query("REPLACE INTO {$tablepre}common_member_field_forum SET uid='$uid'");
$db->query("REPLACE INTO {$tablepre}common_member_field_home SET uid='$uid'");
$db->query("REPLACE INTO {$tablepre}common_member_profile SET uid='$uid'");

$notifyusers = addslashes('a:1:{i:1;a:2:{s:8:"username";s:'.strlen($username).':"'.$username.'";s:5:"types";s:20:"11111111111111111111";}}');
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('notifyusers', '$notifyusers')");
$db->query("UPDATE {$tablepre}common_cron SET lastrun='0', nextrun='".($timestamp + 3600)."'");
$db->query("UPDATE {$tablepre}common_adminnote SET dateline='$timestamp', expiration='".($timestamp + 2592000)."'");

install_data($username, $uid);

$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('portalstatus', '1')");
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('groupstatus', '0')");
$db->query("REPLACE INTO {$tablepre}common_setting (skey, svalue) VALUES ('homestatus', '0')");

dir_clear(ROOT_PATH.'./data/template');
dir_clear(ROOT_PATH.'./data/cache');
dir_clear(ROOT_PATH.'./data/threadcache');

foreach($serialize_sql_setting as $k => $v) {
	$v = addslashes(serialize($v));
	$db->query("REPLACE INTO {$tablepre}common_setting VALUES ('$k', '$v')");
}

$totalmembers = $db->result($db->query("SELECT COUNT(*) FROM {$tablepre}common_member"), 0);
$userstats = ['totalmembers' => $totalmembers, 'newsetuser' => $username];
$data = addslashes(serialize($userstats));
$db->query("REPLACE INTO {$tablepre}common_syscache (cname, ctype, dateline, data) VALUES ('userstats', '1', '$timestamp', '$data')");

save_cli_ucenter_config($db, $tablepre, $siteurl);
@touch($lockfile);

echo "[auto-install] Complete. Admin: {$username} / {$password}".PHP_EOL;
