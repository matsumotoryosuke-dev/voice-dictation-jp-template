# voice-dictation-jp-template

日本語と英語が混ざった話し方でも、そのまま文字にできる macOS 用の音声入力アプリのテンプレートです。オープンソースの音声入力アプリ [VoiceInk](https://github.com/Beingpax/VoiceInk)（GPL-3.0）をもとに、次の変更を加えています。

> This is a template for a macOS push-to-talk dictation app that handles Japanese and English mixed in one sentence. It is a modified version of [VoiceInk](https://github.com/Beingpax/VoiceInk) by Beingpax, licensed under GPL-3.0. English summary at the end.

**このリポジトリは VoiceInk の公式版ではありません。** VoiceInk の作者は、ビルド済みのアプリを有料で配布しています。開発を支援したい方は [tryvoiceink.com](https://tryvoiceink.com) をご覧ください。

---

## 何が違うか

| 追加・変更したこと | 何のためか |
|---|---|
| **Soniox のリアルタイム認識を前提にした設定** | 日本語の文中に英単語が入る話し方を、もっとも正確に文字にできたのが Soniox（`stt-rt-v5`）でした。キーを離してから約0.1秒で確定します。 |
| **クラウドが失敗したらローカルの Whisper に切り替える** | ネット切断・キーの拒否・空の返答のときは、端末内の Whisper で文字にし、切り替えたことを画面に出します。 |
| **右 Command キーの誤作動を防ぐ** | 右 Command を他のキーやクリックと一緒に押したときに、録音が始まってしまう不具合を防ぎます。 |
| **日本語のフィラー除去** | 「えっと」「えー」「うーん」「あのー」などを消します。「まあ」は文頭か読点の前で消し、「あの」「その」は読点の前だけで消します。「あの件」「その件」は残ります。 |
| **辞書の自動学習を日本語と Electron アプリで動くように修正** | 貼り付けた後に手で直した語を拾い、ローカル AI（Ollama）が辞書に入れるか判定します。Claude・Notion・Obsidian・Slack など Electron 製のアプリでも拾えるようにし、チャット欄で送信した後でも直した内容が消えないようにしました。AI が却下した修正も一覧にチェックなしで出るので、最終判断は自分でできます。AI が判定を返さなかった修正は、却下扱いにせず見直し待ちに戻し、警告を出します。 |
| **共有語彙ファイル** | `~/.config/dictation/vocabulary.json` を辞書と双方向で同期します。他のツールからも同じ語彙を使えます。 |
| **口述ごとの記録** | `~/.config/dictation/dictation-log.jsonl` に、口述の長さ・音量・どの経路で文字になったか・かかった秒数を1行ずつ残します（本文は残しません）。 |
| **Soniox の利用額をダッシュボードに表示** | Soniox の利用 API から、今月と先月の請求額を表示します。 |
| **自己署名の証明書でビルドを固定** | ビルドし直すたびに macOS のアクセシビリティ・マイク権限が外れる問題を避けます。 |
| **自動アップデートを止める** | 本家の自動アップデートは公式版の VoiceInk を入れるので、このテンプレートの変更がすべて消えてしまいます。そのため、`make local` で作ったアプリでは自動アップデートを止め、「Check for Updates」も表示しません。本家の新しい変更を取り込むときは、このテンプレートの変更を新しい本家に移植してからビルドします。 |

変更したファイルの一覧は [NOTICE.md](NOTICE.md)、設計の詳細は [docs/TECHNICAL_SPEC.md](docs/TECHNICAL_SPEC.md) にあります。

## 版

- **このリリース**：タグ `v2.21-jp.2`。版を固定したいときは、このタグを指定して取得してください。`main` ブランチは後から変わることがあります。

  ```bash
  git clone --branch v2.21-jp.2 https://github.com/matsumotoryosuke-dev/voice-dictation-jp-template.git
  ```

- **元にした本家**：Beingpax/VoiceInk のコミット `c09cc1f`（2026-10-01。アプリの表示上の版は 2.21）
- **このリポジトリの最初のコミット `d04a88f`** は、その本家をそのまま取り込んだものです。`git diff d04a88f v2.21-jp.2` で、このテンプレートの変更をすべて見られます。
- GitHub の「Use this template」で作ったリポジトリには、この履歴とタグは引き継がれません。

## 必要なもの

- macOS 14.4 以降（動作確認は Apple Silicon の Mac のみ。Intel の Mac では未確認）
- Xcode（App Store から。インストール後に一度起動して利用規約に同意）
- 空き容量：ビルドに約 3.5GB、ローカルの Whisper モデルを使うならさらに約 1.7GB
- 任意：[Soniox](https://soniox.com) の API キー（従量課金。リアルタイム認識は1時間あたり約 $0.12）
- 任意：辞書の自動学習を使うなら [Ollama](https://ollama.com) と、約 10GB のメモリを使う 12B クラスのモデル

## ビルド

```bash
make local
```

できあがったアプリは `~/Downloads/VoiceInk.app` に置かれます。`/Applications` に移してから開いてください。

**権限が毎回外れないようにする（推奨）**：キーチェーンアクセスで「証明書アシスタント → 証明書を作成」を開き、名前を `VoiceInk Local`、種類を「コード署名」にして自己署名証明書を作ってください。`make local` はこの証明書を見つけると、自動でビルドに署名します。署名しないビルドでは、ビルドし直すたびにアクセシビリティとマイクの許可を入れ直す必要があります。

テストは Xcode なしでも動きます。

```bash
make test-core
```

## 最初の設定

1. システム設定 → プライバシーとセキュリティで、VoiceInk に「マイク」「アクセシビリティ」を許可する
2. VoiceInk の Settings → AI Models → Cloud で Soniox の API キーを入れ、「Soniox V5」を選ぶ
3. ローカルの代替として、Whisper large-v3-turbo を VoiceInk 内でダウンロードする
4. Shortcuts で右 Command・Hybrid（押して切り替え、長押しで押している間だけ録音）を選ぶ
5. macOS 標準の音声入力のショートカットは、二重に反応しないようにオフにする
6. Dictionary に、自分がよく使う固有名詞を入れる。誤認識されやすい語は Word Replacements にも入れる

## ライセンス

GPL-3.0。元の VoiceInk と同じライセンスです。詳細は [LICENSE](LICENSE)、元の README は [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md) にあります。VoiceInk の名前とアイコンは原作者のものです。

---

## English summary

A modified [VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL-3.0) tuned for speakers who mix Japanese and English inside one sentence:

- Soniox real-time (`stt-rt-v5`) as the primary engine, with your vocabulary sent as context
- Cloud-to-local fallback to on-device Whisper when the network, the key or the answer fails, announced on screen
- Right-Command hybrid shortcut that no longer fires when combined with other keys or a click
- Japanese filler removal that leaves real words intact
- Auto Learn that actually captures hand corrections in Electron apps and in chat boxes, segments Japanese correctly, survives a slow local reviewer, and shows the reviewer's rejections for you to override
- A shared vocabulary file with two-way sync, a per-dictation journal (no text), and Soniox spend on the dashboard
- Self-signed signing so rebuilds keep macOS permissions
- No self-update in local builds, because upstream's updater would install the official app over this one

This release is tagged `v2.21-jp.2` and is based on upstream commit `c09cc1f` (2026-10-01); this repository's first commit `d04a88f` holds that upstream unchanged. Build with `make local`; test with `make test-core`. This is not an official VoiceInk release; the VoiceInk name and icon belong to its author.
