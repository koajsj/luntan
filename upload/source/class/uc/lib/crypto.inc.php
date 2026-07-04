<?php

/**
 * [UCenter] (C)2001-2099 Discuz! Team
 * This is NOT a freeware, use is subject to license terms
 * https://license.discuz.vip
 */

!defined('IN_UC') && exit('Access Denied');

const UC_CRYPTO_PREFIX = 'dzenc:v1:';
const UC_CRYPTO_SEARCH_PREFIX = 'dzidx:v1:';

function uc_crypto_key($purpose = 'default') {
	$master = defined('UC_KEY') ? UC_KEY : '';
	if($master === '' && function_exists('getglobal')) {
		$master = (string)getglobal('authkey');
	}
	if($master === '') {
		return '';
	}
	return hash_hmac('sha256', 'discuz-ucenter-'.$purpose, $master, true);
}

function uc_crypto_random($length) {
	if(function_exists('random_bytes')) {
		return random_bytes($length);
	}
	if(function_exists('openssl_random_pseudo_bytes')) {
		return openssl_random_pseudo_bytes($length);
	}
	return '';
}

function uc_encrypt_string($plaintext, $purpose = 'default') {
	if($plaintext === '' || strncmp($plaintext, UC_CRYPTO_PREFIX, strlen(UC_CRYPTO_PREFIX)) === 0) {
		return $plaintext;
	}
	if(!function_exists('openssl_encrypt')) {
		return $plaintext;
	}
	$key = uc_crypto_key($purpose);
	$iv = uc_crypto_random(12);
	if($key === '' || strlen($iv) !== 12) {
		return $plaintext;
	}
	$tag = '';
	$ciphertext = openssl_encrypt($plaintext, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
	if($ciphertext === false || $tag === '') {
		return $plaintext;
	}
	return UC_CRYPTO_PREFIX.base64_encode($iv.$tag.$ciphertext);
}

function uc_decrypt_string($value, $purpose = 'default') {
	if(!is_string($value) || strncmp($value, UC_CRYPTO_PREFIX, strlen(UC_CRYPTO_PREFIX)) !== 0) {
		return $value;
	}
	if(!function_exists('openssl_decrypt')) {
		return $value;
	}
	$payload = base64_decode(substr($value, strlen(UC_CRYPTO_PREFIX)), true);
	if($payload === false || strlen($payload) < 29) {
		return $value;
	}
	$key = uc_crypto_key($purpose);
	if($key === '') {
		return $value;
	}
	$iv = substr($payload, 0, 12);
	$tag = substr($payload, 12, 16);
	$ciphertext = substr($payload, 28);
	$plaintext = openssl_decrypt($ciphertext, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
	return $plaintext === false ? $value : $plaintext;
}

function uc_searchable_hash($plaintext, $purpose = 'default') {
	$key = uc_crypto_key($purpose.'.lookup');
	if($key === '') {
		return '';
	}
	return hash_hmac('sha256', (string)$plaintext, $key);
}

function uc_searchable_encrypted($value) {
	return is_string($value) && strncmp($value, UC_CRYPTO_SEARCH_PREFIX, strlen(UC_CRYPTO_SEARCH_PREFIX)) === 0;
}

function uc_encrypt_searchable_string($plaintext, $purpose = 'default') {
	if($plaintext === '' || uc_searchable_encrypted($plaintext)) {
		return $plaintext;
	}
	$ciphertext = uc_encrypt_string($plaintext, $purpose);
	$hash = uc_searchable_hash($plaintext, $purpose);
	if($ciphertext === $plaintext || $hash === '') {
		return $plaintext;
	}
	return UC_CRYPTO_SEARCH_PREFIX.$hash.':'.$ciphertext;
}

function uc_decrypt_searchable_string($value, $purpose = 'default') {
	if(!uc_searchable_encrypted($value)) {
		return $value;
	}
	$pos = strpos($value, ':', strlen(UC_CRYPTO_SEARCH_PREFIX));
	if($pos === false) {
		return $value;
	}
	return uc_decrypt_string(substr($value, $pos + 1), $purpose);
}

function uc_searchable_like($plaintext, $purpose = 'default') {
	$hash = uc_searchable_hash($plaintext, $purpose);
	return $hash === '' ? '' : UC_CRYPTO_SEARCH_PREFIX.$hash.':%';
}
