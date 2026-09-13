# talos-custom-build

Talos Linux のカスタムビルド。SecureBoot 署名を行い、UFS の追加オプションを足す。

## なぜカスタムビルドが必要か

**SecureBoot**: 自前の鍵で署名した UKI と、キー登録用の auto-enrollment ISO を作る。署名鍵はクラスタ内 (1Password) にあり GitHub には渡さないので、署名は Argo Workflows 側で行う。

**UFS の追加オプション**: 元々の動機は CP ノード (Minisforum S100) の UFS ストレージ (`8086:54ff`, Alder Lake-N UFS Controller) が標準カーネルで `CONFIG_SCSI_UFSHCD is not set` だったこと。**この前提は Talos v1.14 で変わり、上流が `CONFIG_SCSI_UFSHCD=m` / `CONFIG_SCSI_UFSHCD_PCI=m` を持つようになった**（v1.13 系には無い）。いま `kernel/ufs.config` が足しているのは、上流が設定しない `SCSI_UFS_BSG` / `SCSI_UFS_DWC_TC_PCI` / `SCSI_UFSHCD_PLATFORM` の 3 つ。

現時点でクラスタに UFS のノードは無い（CP は 2026-08-15 に AOOSTAR N1 Pro / SATA M.2 へ置換、worker は NVMe と SATA）。UFS のハードウェアを再び入れる予定があるためカーネル側は残してある。

## ビルドパイプライン

```
GHA (build.yml)                        Argo Workflows (home-cluster)
┌────────────────────────────┐         ┌──────────────────────────────────────┐
│ kernel (UFS config 追加)   │         │ imager (SecureBoot 署名)             │
│ installer-base             │         │  ├─ secureboot-installer → GHCR     │
│ imager                     │─webhook→│  ├─ secureboot-iso      → GH Release│
│ Pre-release 作成           │         │  └─ iso (PXE assets)   → GH Release│
└────────────────────────────┘         │ finalize-release (pre→release)      │
                                       └──────────────────────────────────────┘
```

- **GHA**: カスタムカーネル + imager ビルド（秘密不要）
- **Argo WF**: SecureBoot 署名（署名鍵はクラスタ内 1Password 管理、GitHub に渡らない）
- **トリガー**: 手動 (`workflow_dispatch`) or 毎週月曜に新 Talos リリースを自動チェック (`check-release.yml`)

### 成果物

| 成果物 | 保存先 | 用途 |
|--------|--------|------|
| `kernel` | GHCR | UFS 対応カスタムカーネル |
| `installer-base` | GHCR | imager のベースイメージ |
| `imager` | GHCR | SecureBoot 署名用 imager |
| `installer` | GHCR | SecureBoot 署名済みインストーラー (`talosctl upgrade` で使用) |
| `metal-amd64-secureboot.iso` | GitHub Release | SecureBoot ISO (auto-enrollment 用 .auth 含む) |
| `metal-amd64.iso` | GitHub Release | 通常 ISO |
| `vmlinuz-amd64`, `initramfs-amd64.xz` | GitHub Release | PXE ブート用 |

## カーネル設定

`kernel/ufs.config` で UFS サポートを追加:

```
CONFIG_SCSI_UFSHCD=y
CONFIG_SCSI_UFS_BSG=y
CONFIG_SCSI_UFSHCD_PCI=y
CONFIG_SCSI_UFS_DWC_TC_PCI=y
CONFIG_SCSI_UFSHCD_PLATFORM=y
```

`scripts/apply-kernel-config.sh` で Talos の pkgs カーネル config にマージし、`make kernel-olddefconfig` で依存関係を解決する。

## SecureBoot

### カーネル引数

SecureBoot プロファイルはデフォルトで `lockdown=confidentiality` を設定するが、`bpf_probe_read` をブロックして Tetragon/Cilium eBPF が壊れる。imager で以下を指定して上書き:

```
--extra-kernel-arg "-lockdown"
--extra-kernel-arg "lockdown=integrity"
```

### installer vs ISO

| | `secureboot-installer` | `secureboot-iso` |
|---|---|---|
| 用途 | アップグレード (`talosctl upgrade`) | 初回セットアップ / キー登録 |
| ESP に .auth 配置 | しない | する (`loader/keys/auto/`) |
| 前提 | UEFI にキー登録済み | UEFI Setup Mode |

`secureboot-installer` は設計上、キー登録済み環境でのアップグレード用。初回のキー登録には `secureboot-iso` を USB に焼いてブートするか、UEFI Shell で手動配置が必要。

### UEFI キー登録手順

→ [home-cluster/docs/secureboot.md](https://github.com/Tsuguya-HC/home-cluster/blob/main/docs/secureboot.md)

## System Extensions

Argo Workflow の imager で `--system-extension-image` として組み込む:

| Extension | Image | 用途 |
|-----------|-------|------|
| iscsi-tools | `ghcr.io/tsuguya/iscsi-tools:v0.2.0-pre-consolidation` | iSCSI (Trident CSI) |
| spin | `ghcr.io/siderolabs/spin:v0.22.0` | containerd-shim-spin (SpinKube / Wasm) |

## iscsi-tools 互換性

siderolabs/extensions `fb4eb042` で iscsi-tools がホスト rootfs 配置から自己完結型コンテナに変更され、ホストの `/usr/local/sbin/iscsiadm` が消失。Trident CSI が iSCSI マウント不能になる。

対策として旧版をミラーして pin:

```
ghcr.io/tsuguya/iscsi-tools:v0.2.0-pre-consolidation
```

→ 詳細: [home-cluster/docs/known-issues.md](https://github.com/Tsuguya-HC/home-cluster/blob/main/docs/known-issues.md#iscsi-tools-extension-のホストバイナリ消失)

## Argo Workflows 関連ファイル (home-cluster)

| ファイル | 内容 |
|----------|------|
| `manifests/argo/talos-secureboot-build.yaml` | WorkflowTemplate + SA + RBAC |
| `manifests/argo/talos-build-scripts.yaml` | push-installer.sh, push-iso.sh, finalize-release.sh |
| `manifests/argo/talos-build-sensor.yaml` | Sensor (release webhook → WF trigger) |
| `manifests/secrets/argo-secureboot-signing-keys.yaml` | 署名鍵 (1Password → Secret) |
