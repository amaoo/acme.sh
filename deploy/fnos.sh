#!/usr/bin/bash
# This deployment requires fnos and root
fnos_deploy() {
  _cdomain="$1"
  _ckey="$2"
  _ccert="$3"
  _cca="$4"
  _cfullchain="$5"
  _fnos_cert_path="${FNOS_CERT_PATH:-$(_readdomainconf FNOS_CERT_PATH)}"

  if [ -z "$_fnos_cert_path" ]; then
    _err "没找到 Fnos 证书路径"
    return 1
  fi

  # 去除末尾斜杠，统一拼接，避免传入带/不带斜杠路径时出问题
  _fnos_cert_path="${_fnos_cert_path%/}"

  _debug _cdomain "$_cdomain"
  _debug _ckey "$_ckey"
  _debug _ccert "$_ccert"
  _debug _cca "$_cca"
  _debug _cfullchain "$_cfullchain"
  _debug _fnos_cert_path "$_fnos_cert_path"

  _crt_file="$_fnos_cert_path/fullchain.crt"
  _key_file="$_fnos_cert_path/$_cdomain.key"

  # 备份现有证书文件（如果存在）
  if [ -f "$_crt_file" ]; then
    /bin/cp -f "$_crt_file" "$_crt_file.bak" || { _err "备份 crt 失败"; return 1; }
  fi
  if [ -f "$_key_file" ]; then
    /bin/cp -f "$_key_file" "$_key_file.bak" || { _err "备份 key 失败"; return 1; }
  fi

  # 放置新证书文件
  /bin/cp -f "$_cfullchain" "$_crt_file" || { _err "复制 fullchain 失败"; return 1; }
  /bin/cp -f "$_ckey" "$_key_file" || { _err "复制 key 失败"; return 1; }

  # 权限设置
  chown root:root "$_crt_file" "$_key_file"
  chmod 644 "$_crt_file"
  chmod 600 "$_key_file"


  # 更新数据库的证书到期日期
  _expiry_date=$(openssl x509 -enddate -noout -in "$_crt_file" | sed "s/^.*=\(.*\)$/\1/")
  if [ -z "$_expiry_date" ]; then
    _err "读取证书到期时间失败"
    return 1
  fi

  _expiry_timestamp=$(date -d "$_expiry_date" +%s%3N)
  _info "更新数据库证书的有效期到: $_expiry_date"

  if ! psql -U postgres -d trim_connect -c "UPDATE cert SET valid_to=$_expiry_timestamp WHERE domain='$_cdomain'"; then
    _err "数据库证书有效期更新失败"
    return 1
  fi
  _info "数据库证书有效期更新完成"

  # 重启服务
  _info "重启服务..."
  for svc in webdav.service smbftpd.service trim_nginx.service; do
    if ! systemctl restart "$svc"; then
      _err "重启 $svc 失败"
      _send_notify "部署 $_cdomain 到 Fnos 时重启 $svc 失败"
      return 1
    fi
  done

  _info "成功将 $_cdomain 部署到 Fnos"
  _send_notify "成功将 $_cdomain 部署到 Fnos"
  return 0
}
