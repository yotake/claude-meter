# ClaudeMeter

### ⬇️ [ClaudeMeter (.dmg) をダウンロード](https://github.com/yotake/claude-meter/releases/latest)

**[English README here](README.md)**

macOS メニューバーに Claude の使用量をリアルタイム表示する軽量アプリです。

> ClaudeMeter は無料です。役に立ったら **[開発を支援 ❤️](https://github.com/sponsors/yotake)** していただけると励みになります。

## スクリーンショット

<p align="center">
  <img src="assets/screenshot-ja.png" width="300" alt="ClaudeMeter ポップオーバー（日本語）">
  &nbsp;&nbsp;
  <img src="assets/screenshot-en.png" width="300" alt="ClaudeMeter popover (English)">
</p>

<p align="center"><em>設定パネル（展開時）</em></p>

<p align="center">
  <img src="assets/screenshot-settings-ja.png" width="300" alt="ClaudeMeter 設定（日本語）">
  &nbsp;&nbsp;
  <img src="assets/screenshot-settings-en.png" width="300" alt="ClaudeMeter settings (English)">
</p>

UI は macOS の言語設定（日本語 / 英語）に追従します（**設定 → 言語**で手動切り替えも可能）。

## 表示できるもの

claude.ai の **設定 → 使用状況 (Settings → Usage)** と同じ数値をメニューバーで確認できます。

- **現在のセッション** — 5時間枠の利用率（リセットまでの残り時間つき）
- **週間リミット** — 全モデル / Sonnet のみ / Opus のみ（リセット曜日つき）
- **Codex レート制限**（任意）— ローカルの Codex CLI ログから読み取り
- **API 支出**（任意）— Claude の **Admin** キーで今月の支出を表示
- **複数アカウント** — 複数のサブスク / キーを同時に表示

メニューバーには選択中アカウントのセッション利用率（例: `21%`）が、消費ペース予測で色づけされて常駐表示されます（リセット前に使い切るペースだとアイコンが警告表示に変わります）。アイコンをクリックすると、予測（「このペースで HH:mm に上限到達」をセッション行の上に表示）を含む詳細を確認できます。

ポップオーバー下部には GitHub リポジトリと最新リリースページへのリンクもあります。アップデートは現時点では手動です。アプリ内の **更新** から GitHub Releases を開き、新しい DMG があればダウンロードして Applications 内のアプリを置き換えてください。

## 仕組み

`https://api.anthropic.com/api/oauth/usage` を **5分間隔**でポーリングして、Claude サブスクリプション（5時間セッション・7日間リミット）の使用量を取得します。このエンドポイントには **`user:profile` スコープを持つ OAuth トークン**が必要です。

### 認証方式

ClaudeMeter は macOS Keychain に**直接アクセスしません**（ad-hoc 署名アプリが Keychain を参照するとアンチウイルスが警告を出すことがあるため）。代わりに、`claude` CLI がすでに管理している OAuth トークンをポップオーバーに一度貼り付けてもらう方式です。

貼り付けたトークンは `~/Library/Application Support/ClaudeMeter/credentials.json`（パーミッション `0600`）に保存され、アプリが**リフレッシュトークンで自動更新**するため通常は再貼り付け不要です。

> **注意**: 初回の自動更新でリフレッシュトークンがローテーションされるため、`claude` CLI が次回起動時に再ログインを求めることがあります。その後は ClaudeMeter と CLI が独立してトークンを管理します。

### HTTP 429 (Rate Limit) について

使用量エンドポイントはポーリングを積極的に制限します。429 を受け取ると、サーバーの `Retry-After`（+60秒）だけ待って自動回復します。更新ボタンを連打しないでください。

## 必要環境

- macOS 13 (Ventura) 以降
- Claude **Max / Pro** サブスクリプション（使用量エンドポイントへのアクセスに必要）
- *（ソースからビルドする場合のみ）* Swift Command Line Tools — `xcode-select --install`

## インストール（配布DMG）

1. [Releases](https://github.com/yotake/claude-meter/releases) から `ClaudeMeter-<version>.dmg` をダウンロードして開き、`ClaudeMeter.app` をアプリケーションフォルダへドラッグします。
2. 配布ビルドは現在 **ad-hoc 署名（未公証）** のため、初回起動時に Gatekeeper にブロックされます。以下いずれかで許可してください。
   - `ClaudeMeter.app` を右クリック → **開く** → ダイアログで **開く**
   - **システム設定 → プライバシーとセキュリティ** → **このまま開く**
   - ターミナルで隔離属性を除去:
     ```sh
     xattr -d com.apple.quarantine /Applications/ClaudeMeter.app
     ```
3. メニューバーアイコンをクリックし、トークンを貼り付けます（下記「トークンの設定」参照）。

### アップデート

ClaudeMeter のポップオーバーで **更新** をクリックすると、最新の GitHub Release を開きます。新しい DMG がある場合はダウンロードし、Applications 内のアプリを置き換えてください。自動アップデートはまだ内蔵していません。

## トークンの設定

`claude` CLI を使っている場合、ターミナルで次を実行するとトークンがクリップボードにコピーされます:

```sh
security find-generic-password -s "Claude Code-credentials" -w | pbcopy
```

`security` は Apple 署名済みの標準 CLI です。Keychain 許可ダイアログが出たら **許可** を選択してください（ClaudeMeter 本体は Keychain にアクセスしません）。コピーできたらポップオーバーを開いて入力欄に貼り付け、**保存** を押します。「認証済み（自動更新）」と表示され、以降はアプリがトークンを自動更新します。

任意:
- 代わりに Claude の **Admin** キー（`sk-ant-admin…`）を貼ると今月の API 支出を表示できます。
- ログが既定の `~/.codex/sessions` 以外にある場合は、設定で **Codex セッションフォルダ** を指定できます（`CODEX_HOME` 環境変数も参照します）。

## ソースからビルド

```sh
./build.sh
open ClaudeMeter.app
```

## ログイン時に自動起動

**システム設定 → 一般 → ログイン項目と機能拡張** で `ClaudeMeter.app` を追加してください。

## リリースをビルドする

`release.sh` は Apple Silicon と Intel 両対応の Universal Binary DMG を `dist/` に生成します:

```sh
./release.sh                 # ad-hoc 署名のDMG（受け取った人にGatekeeper警告が出る）
```

Gatekeeper 警告の出ない **公証済み** DMG を作るには（Apple Developer Program メンバーシップが必要）、署名IDと公証認証情報を設定して再実行します。環境変数の詳細は `release.sh` 冒頭のコメントを参照:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="claude-meter" \
./release.sh
```

秘密情報はリポジトリに書き込みません（実行時に環境変数 / ログインキーチェーンから読むだけ）。

## 支援

ClaudeMeter は無料・オープンソースで、**1970年代生まれ・3歳と5歳の二児の父**の個人開発です。役に立ったら **[GitHub Sponsors ❤️](https://github.com/sponsors/yotake)** での少額のご支援が、**Apple Developer Program**（年 $99）の費用の補填になり、アプリを公証（Gatekeeper 警告なし）して継続メンテナンスする力になります。応援よろしくお願いします！🙏

## 注意事項

- 非公開 API (`/api/oauth/usage`) を利用し、ローカルの CLI トークン／ログを読みます。将来 Anthropic / OpenAI 側の変更で動作しなくなる可能性があります。
- トークン失効でエラーが出た場合は、新しいトークンを取得し直し（`claude` を一度実行 → 再度 `security … | pbcopy`）、ポップオーバーの **トークン更新** から貼り直してください。
