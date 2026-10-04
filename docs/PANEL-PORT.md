# MT5700M 5G 模组管理面板 —— Debian 移植说明

> 目标：把上游项目 [LianXia233/luci-app-mt5700](https://github.com/LianXia233/luci-app-mt5700)
> **原样**移植到本机的 Debian 13 rootfs（Hiveton H5000M，ARM64）。
> 前端 JS/CSS **一行未改**；不重写界面，只补齐它依赖的运行时与后端。

## 1. 架构

```
浏览器 ──HTTP(8181)──> mt5700-web ──TCP newline-JSON(127.0.0.1:8765)──> at-webserver ──串口──> MT5700M
                         │                                                 (Rust，AT 会话/URC/短信/扫频)
                         ├─ 静态资源：luci-base 运行时 + 项目前端（原样）
                         └─ ubus JSON-RPC：session/system/luci/uci/file/service/rc/log/mt5700
```

* `at-webserver`：项目自带的 Rust 后端（AT 客户端 + RPC）。
  从上游编译，**仅修了一个上游 bug**（见 §5）。
* `mt5700-web`：本移植新增的薄服务（Rust，单文件，无第三方依赖除 serde_json）：
  1. 提供静态文件（`/`、`/luci-static/**`）；
  2. 实现 LuCI 前端需要的 ubus JSON-RPC 对象；
  3. 把 `mt5700.at / events / logs` 转发到 `at-webserver`。

## 2. LuCI 运行时（vendor，未改）

`/usr/share/mt5700-panel/www/luci-static/resources/` 取自 **openwrt/luci (openwrt-24.10)**，
与 ImmortalWrt 24.10 对应：

```
luci.js  rpc.js  uci.js  fs.js  ui.js  form.js  validation.js  cbi.js
network.js  firewall.js  icons/  protocol/  tools/  view/bootstrap/
```

内置 require 别名（`baseclass` / `dom` / `poll` / `request` / `session` / `view`）
由 `luci.js` 自行注册，无需额外文件。

项目前端原样放置：

```
luci-static/resources/at-webserver/      compat.js  mt5700.js  mt5700.css  at.css
                                         parse.js  rpc.js  smsEncode.js  ui.js
luci-static/resources/view/at-webserver/ 12 个页面视图（network_status … service）
```

## 3. 外壳（等价 header.ut / footer.ut / view.ut）

* `/index.html`：注入 `L.env`（`resource` / `ubuspath` / `dispatchpath` / `sessionid` …）、
  生成导航，然后调用 `ui.instantiateView('at-webserver/<page>')` ——
  与 LuCI 的 `ucode/template/view.ut` 完全一致，因此视图的 load/render 生命周期不变。
* `/panel-shell.css`：外壳样式，**复用项目 `mt5700.css` 的 `--mt5700-*` 设计 token**。

### 为什么默认**不加载** LuCI 主题 CSS（cascade.css）

主题用 `background` 简写 + `!important` 覆盖控件（项目 CSS 里对此有专门注释），实测导致：

1. 下拉框文字被裁掉一半（高度/行高被压扁）；
2. 按钮、输入框与页面卡片风格不一致。

因此外壳改用项目 token + 面板自带兜底控件样式，整页观感统一。
LuCI 通用“保存/应用”底栏（项目页面自带操作按钮，用不到）与面包屑一并隐藏；
`#modal_overlay` 需要 `body.modal-overlay-active` 才显示，已在面板样式中补齐。

## 4. 后端 RPC 实现（mt5700-web）

| 对象 | 方法 | 说明 |
| --- | --- | --- |
| `mt5700` | `at` / `events` / `logs` | 转发到 at-webserver（带 `_rid`、`auth_key`） |
| `mt5700` | `netrate` / `usb` | 移植自项目 `mt5700.uc`：读 `/sys/class/net/*/statistics`、`/sys/bus/usb/devices` |
| `uci` | `get` / `set` / `delete` / `add` / `order` / `changes` / `commit` / `apply` / `confirm` | 读写 `/etc/config/<pkg>`（UCI 文本格式，解析后立即落盘） |
| `file` | `read` / `write` / `list` / `stat` / `remove` / `exec` | 形状与 OpenWrt `rpcd` 一致（`stat` 扁平、`entries[]`、`read→{data}`）；写入限 `/etc/config/`、`/tmp/`、`/var/`、`/root/`；`exec` 白名单 |
| `service` / `rc` | `list` / `set` / `init` / `delete` | 映射到 systemd（仅允许 `at-webserver`、`mt5700-web`） |
| `log` | `read` | 本项目通知日志 + `journalctl -u at-webserver -u mt5700-web` |
| `session` / `system` / `luci` | `login/get/access/destroy`、`board/info`、`getFeatures` | 本地单机桩：会话恒有效、ACL 全开 |

另保留两个直连入口（调试用）：`POST /rpc`（原样转发）、`GET /api/at?cmd=`。

## 5. 顺带修掉的上游 bug：串口自动探测

`serialdetect.rs::probe_at()` 只按 `\n` 分行。模组上一次会话异常关闭时会在缓冲区留下
**没有换行的 NUL 垃圾**（`^@^@^@`），于是 `OK` 被拼进同一行 → 整行匹配失败 →
“候选串口都没有正常应答 AT”，明明可用的 `ttyUSB1` 被跳过（真机复现过）。
修复：同时按 `\r` 与 `\n` 分行，并跳过空行。

```text
build/luci-app-mt5700/src/rust/src/serialdetect.rs     （唯一改动的上游文件）
```

## 6. 部署形态（rootfs 内）

```text
/usr/bin/at-webserver-rust              项目 Rust 后端（AT + RPC 8765）
/usr/bin/mt5700-web                     面板服务（HTTP 8181 + ubus 后端）
/usr/bin/uci                            极简 uci 兼容层（show/set/commit，供 at-webserver 读配置）
/etc/config/at-webserver                后端配置（串口/拨号/通知/定时锁频）
/etc/systemd/system/at-webserver.service
/etc/systemd/system/mt5700-web.service
/usr/share/mt5700-panel/www/            面板站点（LuCI 运行时 + 项目前端 + index.html + panel-shell.css）
```

开机自启：两个 unit 均已 `enable`（`multi-user.target.wants/`）。

访问：`http://<设备IP>:8181/`（默认无鉴权）。
防火墙：`/etc/nftables.conf` 的 `table inet h5000m_mgmt` 在 5G 上行口
（`enx*`/`wwan*`/`usb*`）丢弃 8181，只允许内网访问。需要鉴权可用
`--auth 用户:口令` 启动 `mt5700-web`。

## 7. 重新构建 / 更新面板

```bash
# 1) 后端（容器 mt7987 内，需 rustup 的 stable 工具链）
docker exec mt7987 bash -lc 'cd /w/mt5700-web && PATH=/root/.cargo/bin:$PATH cargo build --release'
docker exec mt7987 bash -lc 'cd /w/luci-app-mt5700/src/rust && PATH=/root/.cargo/bin:$PATH cargo build --release'

# 2) 同步到 rootfs 暂存区
docker cp build/mt5700-panel/www            mt7987:/build/rootfs/usr/share/mt5700-panel/
docker cp build/mt5700-web/target/release/mt5700-web mt7987:/build/rootfs/usr/bin/
docker cp build/luci-app-mt5700/src/rust/target/release/at-webserver mt7987:/build/rootfs/usr/bin/at-webserver-rust

# 3) 打包镜像
docker exec mt7987 bash -lc 'cd /w && bash ./package-h5000m-udev.sh'
```

真机快速更新（不改镜像）：把 `www/`、二进制、unit 打成 tar，设备侧 `tar xzf -C /` 后
`systemctl restart at-webserver mt5700-web`（本项目开发期即用此法验证）。

## 8. 已知限制

* `file.md5` 未实现（前端几乎不用）；`file.exec` 仅允许白名单命令。
* 面板默认无鉴权，依赖“仅内网可达 + nftables 限制”；如需可加 `--auth`。
* `uci.changes` 返回空（写入即落盘，无“未保存变更”概念）。
* 日志页的 syslog 来源为 journal（OpenWrt 上是 logd），字段格式已按前端解析需求对齐。
