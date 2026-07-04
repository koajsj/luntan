<?php

/**
 * [Discuz!] (C)2001-2099 Discuz! Team
 * This is NOT a freeware, use is subject to license terms
 * https://license.discuz.vip
 */

if(!defined('IN_DISCUZ')) {
	exit('Access Denied');
}

class table_common_member_security extends discuz_table {
	public static function t() {
		static $_instance;
		if(!isset($_instance)) {
			$_instance = new self();
		}
		return $_instance;
	}

	public function __construct() {

		$this->_table = 'common_member_security';
		$this->_pk = 'securityid';

		parent::__construct();
	}

	public function fetch_auth_session($uid, $fieldid, $sessionid) {
		$uid = dintval($uid);
		if(!$uid || !$fieldid || !$sessionid) {
			return [];
		}
		$data = DB::fetch_first('SELECT * FROM %t WHERE uid=%d AND fieldid=%s AND oldvalue=%s ORDER BY securityid DESC', [$this->_table, $uid, $fieldid, $sessionid]);
		if(!empty($data['newvalue'])) {
			$data['data'] = json_decode($data['newvalue'], true) ?: [];
		}
		return $data;
	}

	public function upsert_auth_session($uid, $username, $fieldid, $sessionid, $data) {
		$uid = dintval($uid);
		if(!$uid || !$fieldid || !$sessionid || !is_array($data)) {
			return false;
		}
		$base = [
			'uid' => $uid,
			'username' => (string)$username,
			'fieldid' => (string)$fieldid,
			'oldvalue' => (string)$sessionid,
			'newvalue' => json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
			'dateline' => TIMESTAMP,
		];
		$current = $this->fetch_auth_session($uid, $fieldid, $sessionid);
		if(!empty($current['securityid'])) {
			return DB::update($this->_table, $base, ['securityid' => $current['securityid']]);
		}
		return DB::insert($this->_table, $base, false, true);
	}

	public function delete_auth_session($uid, $fieldid, $sessionid = '') {
		$uid = dintval($uid);
		if(!$uid || !$fieldid) {
			return 0;
		}
		$where = ['uid' => $uid, 'fieldid' => (string)$fieldid];
		if($sessionid !== '') {
			$where['oldvalue'] = (string)$sessionid;
		}
		return DB::delete($this->_table, $where);
	}

}

