# wglrec

Three.js など任意のシーンモジュールを Web Worker 上でオフラインレンダリングし、WebCodecs と WebM Muxer を使って VP9 の WebM 動画として書き出すデモです。メインスレッドは UI とプレビュー描画のみを担当し、OffscreenCanvas を Worker に移譲して決定的なフレーム生成を行います。

## 機能概要
- 解像度・尺・FPS・ビットレート・キーフレーム間隔を指定してレンダリングを実行し、WebM (VP9) を生成。
- 任意秒のプレビューを ImageBitmap で受け取り、UI 上で確認可能。
- 任意のシーンモジュール（ESM）を URL 指定で読み込み、即座に再描画。
- ログフィードで進捗やエラーメッセージを確認可能。

## 動作要件
- WebCodecs と OffscreenCanvas に対応した最新の Chromium 系ブラウザ。
- CDN からシーンが必要とするライブラリ（例: three.js r159+）と `webm-muxer` を読み込める環境。
- モジュールワーカーが利用可能であること。

## シーンモジュールの作成方法
シーンは ES Modules として実装し、`createSceneController`（または default export）を提供します。ワーカーはこのファクトリ関数から得られるコントローラを通じてレンダー処理を呼び出します。Three.js 等のライブラリはシーン側で `import` してください。

### 必須インターフェース
```ts
export async function createSceneController({
  canvas,   // transferControlToOffscreen() 済みの OffscreenCanvas
  width,    // 初期幅
  height    // 初期高さ
}) {
  // ... Three.js や 2D コンテキストなどの初期化 ...
  return {
    renderer,                 // optional: レンダラー（例: THREE.WebGLRenderer）
    renderFrame: async (tSec) => {}, // 時刻 tSec (秒) で1フレーム描画（Promise可）
    resize?: (w, h) => {},    // optional: サイズ変更時の処理
    dispose?: () => {},       // optional: 後始末
    captureBitmap?: () => {}  // optional: ImageBitmap 取得のカスタム処理
  };
}
```

- `renderFrame(tSec)` はレンダリングループから毎フレーム呼び出されます。`async` 関数として Promise を返して構いません（ワーカー側で await されます）。`tSec` は 0 から開始する実時間（秒）です。
- `resize(w, h)` を実装すると、UI で解像度を変更した際に呼び出されます。カメラのアスペクト更新や `renderer.setSize` を行ってください。
- `dispose()` を実装すると、新しいシーンを読み込む前に呼び出され、リソースの破棄ができます。
- `captureBitmap()` を実装すると、プレビューや進捗通知の際に独自のイメージ取得ロジックを利用できます。未実装の場合は `createImageBitmap(canvas)` にフォールバックします。

### テンプレート
- `scene-default.js` : Three.js の標準ジオメトリとライトを使った基本シーン。
- `shader-template.js` : フルスクリーンクアッドとカスタムシェーダーで最小構成を示すテンプレート。
- `shader-path.js` : フルスクリーンパストレーシングの例。
- `scene-canvas.js` : 2D Canvas API だけで実装した軽量サンプル。
- `shader-chunk.js` ; シェーダのglslファイルをダイナミックロードするもの
- `webgpu-template.js` : webgpuシェーダーサンプル
- `webgpu-chunk.js` ; シェーダのglslファイルをダイナミックロードするwebgpu版

`scene-canvas.js`  は WebGL に依存せず、OffscreenCanvas の 2D コンテキストを活用する例です。

`shader-chunk.js` で使用するglslファイルはchunkフォルダの下にあります。

どちらも `createSceneController` を実装しているので、新しいシーンを作成する際の参考になります。

### 作成と利用手順
1. `wglrec` ディレクトリなど、ブラウザから相対パスでアクセスできる場所に新しい `.js` モジュールを作成します。
2. 上記インターフェースを満たす `createSceneController` を実装し、必要な Three.js のセットアップとアニメーションを記述します。
3. ブラウザで `index.html` を開き、「シーンモジュール」欄の URL に作成したモジュールのパス（例: `./my-scene.js`）を入力し、「シーン再読み込み」を押します。
4. プレビューで動作を確認し、問題なければレンダリングを実行して WebM を取得します。

外部リソースを利用する場合は CORS 制約を満たすようにし、決定論的に再生できるよう時間に依存した処理は `tSec` を利用してください。
