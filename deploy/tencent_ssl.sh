#!/usr/bin/env sh

#export Tencent_SecretId="AKIDz81d2cd22cdcdc2dcd1cc1d1A"
#export Tencent_SecretKey="Gu5t9abcabcaabcbabcbbbcbcbbccbbcb"

tencent_ssl_deploy() {
  _cdomain="$1"
  _ckey="$2"
  _cfullchain="$5"

  _debug _cdomain "$_cdomain"
  _debug _ckey "$_ckey"
  _debug _cfullchain "$_cfullchain"

  Tencent_SecretId="${Tencent_SecretId:-$(_readaccountconf_mutable Tencent_SecretId)}"
  Tencent_SecretKey="${Tencent_SecretKey:-$(_readaccountconf_mutable Tencent_SecretKey)}"

  if [ -z "${Tencent_SecretId}" ]; then
    _err "Please define Tencent_SecretId."
    return 1
  fi
  if [ -z "${Tencent_SecretKey}" ]; then
    _err "Please define Tencent_SecretKey."
    return 1
  fi

  # 获取上次的证书ID
  _getdeployconf DEPLOY_TENCENT_SSL_CURRENT_CERTIFICATE_ID
  old_cert_id="$DEPLOY_TENCENT_SSL_CURRENT_CERTIFICATE_ID"

  _info "old_cert_id: $old_cert_id"

  resource_types="$(_readdomainconf TENCENT_SSL_RESOURCE_TYPES)"
  resource_types_json=$(printf '"%s",' ${resource_types//,/ } | sed 's/,$//')
  [[ -z "$resource_types" ]] && resource_types_json='[]' || resource_types_json="[$resource_types_json]"

  _info "resource_types_json: $resource_types_json"

  # -----------------------------
  # 无论是否存在旧证书和关联资源，先使用 UploadCertificate 上传新证书。
  # -----------------------------
  _info "Uploading new Tencent SSL certificate to get new certificate ID"
  _payload="{\"CertificatePublicKey\":\"$(_json_encode <"$_cfullchain")\",\"CertificatePrivateKey\":\"$(_json_encode <"$_ckey")\",\"Alias\":\"acme.sh $_cdomain\"}"
  if ! new_cert_id="$(tencent_api_request_ssl "UploadCertificate" "$_payload" "CertificateId")"; then
    _err "Failed to upload new certificate."
    return 1
  fi
  _info "New Certificate ID: $new_cert_id"

  # -----------------------------
  # 存在旧证书，并且已关联资源，使用 UpdateCertificateInstance 更新新旧证书资源
  # -----------------------------
  if [ -n "$old_cert_id" ] && [ -n "$resource_types" ]; then
    _info "Resources ($resource_types) associated with $old_cert_id updated to $new_cert_id"

    # 使用新的证书ID (new_cert_id) 替换旧的证书ID (old_cert_id) 关联的资源
    _payload="{\"OldCertificateId\":\"$old_cert_id\",\"CertificateId\":\"$new_cert_id\",\"ResourceTypes\":$resource_types_json}"

    if ! request_id="$(tencent_api_request_ssl "UpdateCertificateInstance" "$_payload" "RequestId")"; then
      _err "Failed to update existing certificate instance."
      # 注意：如果更新失败，此时新证书已上传，但旧证书未替换，应该返回失败。
      return 1
    fi
    _info "New certificate resource update successful: " $request_id

  fi

  # 保存最新证书ID
  _savedeployconf DEPLOY_TENCENT_SSL_CURRENT_CERTIFICATE_ID "$new_cert_id"

#  # -----------------------------
#  # 删除未关联资源的旧证书
#  # -----------------------------
#  if [ -n "$old_cert_id" ]; then
#    _info "Deleted unassociated old certificate: $old_cert_id"
#
#    _payload="{\"CertificateId\":\"$old_cert_id\"}"
#
#    tencent_api_request_ssl "DeleteCertificate" "$_payload" "DeleteResult"
#    _debug delete_result "$delete_result"

  return 0
}


tencent_api_request_ssl() {
  action=$1
  payload=$2
  response_field=$3

  if ! response="$(tencent_api_request "ssl" "2019-12-05" "$action" "$payload")"; then
    _err "Error <$1>"
    return 1
  fi

  err_message="$(echo "$response" | _egrep_o "\"Message\":\"[^\"]*\"" | cut -d : -f 2 | tr -d \")"
  if [ "$err_message" ]; then
    _err "$err_message"
    return 1
  fi

  _debug response "$response"

  #value="$(echo "$response" | _egrep_o "\"$response_field\":\"[^\"]*\"" | cut -d : -f 2 | tr -d \")"
  value="$(echo "$response" | _egrep_o "\"$response_field\":[^\,}]*" | cut -d : -f 2 | tr -d '", \t\n\r')"

  if [ -z "$value" ]; then
    _err "$response_field not found"
    return 1
  fi

  echo "$value"
}

# shell client for tencent cloud api v3 | @author: rehiy
# copy from dns_tencent.sh
tencent_sha256() {
  printf %b "$@" | _digest sha256 hex
}

tencent_hmac_sha256() {
  k=$1
  shift
  hex_key=$(printf %b "$k" | _hex_dump | tr -d ' ')
  printf %b "$@" | _hmac sha256 "$hex_key" hex
}

tencent_hmac_sha256_hexkey() {
  k=$1
  shift
  printf %b "$@" | _hmac sha256 "$k" hex
}

tencent_signature_v3() {
  service=$1
  action=$(echo "$2" | _lower_case)
  payload=${3:-'{}'}
  timestamp=${4:-$(date +%s)}

  domain="$service.tencentcloudapi.com"
  secretId="$Tencent_SecretId"
  secretKey="$Tencent_SecretKey"

  algorithm='TC3-HMAC-SHA256'
  date=$(date -u -d "@$timestamp" +%Y-%m-%d 2>/dev/null)
  [ -z "$date" ] && date=$(date -u -r "$timestamp" +%Y-%m-%d)

  canonicalUri='/'
  canonicalQuery=''
  canonicalHeaders="content-type:application/json\nhost:$domain\nx-tc-action:$action\n"
  _debug2 payload "$payload"

  signedHeaders='content-type;host;x-tc-action'
  canonicalRequest="POST\n$canonicalUri\n$canonicalQuery\n$canonicalHeaders\n$signedHeaders\n$(printf %s "$payload" | _digest sha256 hex)"
  _debug2 canonicalRequest "$canonicalRequest"

  credentialScope="$date/$service/tc3_request"
  stringToSign="$algorithm\n$timestamp\n$credentialScope\n$(tencent_sha256 "$canonicalRequest")"
  _debug2 stringToSign "$stringToSign"

  secretDate=$(tencent_hmac_sha256 "TC3$secretKey" "$date")
  secretService=$(tencent_hmac_sha256_hexkey "$secretDate" "$service")
  secretSigning=$(tencent_hmac_sha256_hexkey "$secretService" 'tc3_request')
  signature=$(tencent_hmac_sha256_hexkey "$secretSigning" "$stringToSign")

  echo "$algorithm Credential=$secretId/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"
}

tencent_api_request() {
  service=$1
  version=$2
  action=$3
  payload=${4:-'{}'}
  timestamp=${5:-$(date +%s)}

  token=$(tencent_signature_v3 "$service" "$action" "$payload" "$timestamp")

  _H1="Authorization: $token"
  _H2="X-TC-Version: $version"
  _H3="X-TC-Timestamp: $timestamp"
  _H4="X-TC-Action: $action"
  _H5="X-TC-Language: en-US"

  _post "$payload" "https://$service.tencentcloudapi.com" "" "POST" "application/json"
}
