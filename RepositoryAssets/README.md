# Package icon before installation

Upload `assets/cydia.png` alongside the DEB to the BarabaDev repository. This is Cydia’s standard 180 × 180 app icon.

The package metadata declares:

```text
Icon: https://barabadev.com/assets/cydia.png
```

Preserve this field when generating the repository’s `Packages` index. Once uploaded, clients can fetch the HTTPS image before Cydia is installed; a local `file://` path cannot serve that purpose.

After uploading, verify that the URL returns the image with HTTP 200. Refresh the source in Cydia or Sileo and inspect Cydia on a device where it is not installed. Existing clients may need to refresh their cached index.

Building this project does not upload the image or publish the package.
