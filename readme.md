# IPA Mach-O 修复与重新签名

本目录提供两套相互独立的工具：

- `repair.sh` / `repair.py`：修复部分注入 IPA 中异常的 Mach-O 旧签名，并生成新的 `_repaired.ipa`。
- `resign.sh`：使用本机 Apple Development 证书和 provisioning profile 对 IPA 重新签名。

原始 IPA 不会被修改。建议始终先保留一份原包备份。

## 适用环境

- macOS
- 已安装 Xcode 或 Xcode Command Line Tools
- 系统可以使用 `python3`、`codesign`、`zip` 和 `unzip`
- 重新签名时，登录钥匙串中存在有效的 Apple Development 证书及私钥
- `embedded.mobileprovision` 与脚本放在同一目录

可以用下面的命令检查签名证书：

```bash
security find-identity -p codesigning -v
```

## 推荐使用流程

### 第一步：修复 IPA

```bash
./repair.sh a.ipa
```

也可以直接调用 Python：

```bash
./repair.py a.ipa
```

默认会在原 IPA 所在目录生成：

```text
a_repaired.ipa
```

这个文件只是修复了异常的 Mach-O 签名结构，仍需执行下一步重新签名。

### 第二步：重新签名

```bash
./resign.sh a_repaired.ipa
```

`resign.sh` 默认生成：

```text
a_repairedNew.ipa
```

此文件是最终重新签名后的 IPA。

## 修改应用名称和 Bundle ID

```bash
./resign.sh a_repaired.ipa \
  -name "myname" \
  -id "com.test.myid"
```

参数说明：

- `-name`：修改桌面显示名称。
- `-id`：修改主应用的 Bundle Identifier。

新的 Bundle ID 必须符合当前 provisioning profile 的 App ID 规则，否则即使签名命令成功，IPA 也可能无法安装。

## repair 脚本参数

### 指定输出文件

```bash
./repair.sh a.ipa -o custom_repaired.ipa
```

### 覆盖已有输出文件

默认情况下，脚本不会覆盖已经存在的输出文件。如确认需要覆盖：

```bash
./repair.sh a.ipa --force
```

### 查看帮助

```bash
./repair.sh --help
```

## repair 脚本会做什么

脚本会自动：

1. 在系统临时目录解压 IPA。
2. 扫描 IPA 内的 Mach-O 文件。
3. 找出签名区域与文件末尾不一致的可疑文件。
4. 在隔离副本中调用 Apple `codesign`，确认旧签名确实无法正常覆盖。
5. 仅修复符合安全条件且确实无法签名的 Mach-O。
6. 修复后再次进行临时签名和严格校验。
7. 重新打包并检查新 IPA 的 ZIP 完整性。
8. 生成独立的 `_repaired.ipa`，不修改原始 IPA。

临时测试使用的是 ad-hoc 签名，只用于验证 Mach-O 能否重新签名。正式证书签名由后续的 `resign.sh` 完成。

## repair 的安全限制

当前修复器针对的是 TrollFools 一类注入工具可能产生的特定损坏模式，不是通用的 IPA 万能修复工具。

自动修复要求目标文件满足以下条件：

- 是小端、单架构、64 位 Mach-O。
- 恰好包含一个 `LC_CODE_SIGNATURE`。
- 恰好包含一个 `__LINKEDIT`。
- 旧签名之后只有全零填充，不包含非零有效数据。
- Apple `codesign` 在隔离副本中确实无法覆盖旧签名。
- 修复后能够重新生成签名并通过严格校验。

如果签名尾部存在非零数据、加载命令结构异常或脚本不能确认修改安全性，脚本会停止，不会强行修改文件。

脚本暂不自动修复 fat/universal 多架构 Mach-O。这类文件会保持原样，并在输出中给出提示。

## repair 不能解决的问题

以下问题通常与本修复器无关：

- Apple Development 证书不存在、过期或缺少私钥。
- 钥匙串没有访问权限。
- provisioning profile 已过期。
- 设备 UDID 不在 provisioning profile 中。
- Bundle ID、App ID 或 Team ID 不匹配。
- entitlements 不符合 provisioning profile。
- App Store 主程序仍处于加密状态。
- dylib 架构与设备不兼容。
- dylib 加载路径错误或依赖文件缺失。
- framework 的 `Info.plist`、资源或嵌套签名存在其他问题。

## 常见问题

### 提示输出文件已存在

为避免误覆盖，repair 默认停止。可以换一个输出名：

```bash
./repair.sh a.ipa -o a_repaired_v2.ipa
```

或明确允许覆盖：

```bash
./repair.sh a.ipa --force
```

### 没有发现符合条件的异常 Mach-O

这表示没有检测到本工具针对的签名损坏模式。脚本仍会生成重新打包后的 `_repaired.ipa`，但不会修改 Mach-O。若后续 `resign.sh` 仍然失败，应根据 `codesign` 的原始错误排查证书、entitlements、fat Mach-O 或其他结构问题。

### repair 成功，但 IPA 仍无法安装

repair 成功只说明异常 Mach-O 已恢复到可以重新签名的状态。请继续检查：

```bash
codesign --verify --deep --strict --verbose=4 Payload/XXX.app
```

同时确认 provisioning profile 的有效期、设备 UDID、Bundle ID 和签名证书是否匹配。

## 文件说明

- `repair.sh`：便捷入口，会调用同目录下的 `repair.py`。
- `repair.py`：负责解包、自动扫描、安全判断、验证和重新打包。
- `repair_macho_signature.py`：底层 Mach-O 签名结构修复器。
- `resign.sh`：现有的 IPA 重新签名脚本，repair 工具不会修改它。

使用 repair 工具时，请保持前三个 repair 文件位于同一目录。
