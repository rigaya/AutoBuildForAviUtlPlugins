# AutoBuildForAviUtlPlugins

ここは、[AviUtl](http://spring-fragrance.mints.ne.jp/aviutl/)用出力プラグインのエンコーダをビルドする場所です。

## 概要

以下のAviUtlプラグイン用のエンコーダの実行ファイルをビルドします。

- [x264guiEx](https://github.com/rigaya/x264guiEx) - x264によるH.264出力プラグイン
- [x265guiEx](https://github.com/rigaya/x265guiEx) - x265によるHEVC出力プラグイン
- [svtAV1guiEx](https://github.com/rigaya/svtAV1guiEx) - SVT-AV1によるAV1出力プラグイン

## ビルドスクリプト

各エンコーダのビルドスクリプトは以下のディレクトリにあります：

- x264: `x264/build_x264.sh`
- x265: `x265/build_x265.sh`
- SVT-AV1: `svtav1/build_svtav1.sh`
