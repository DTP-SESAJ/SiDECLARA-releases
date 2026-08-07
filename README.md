# SiDECLARA releases

Artefactos públicos de instalación de **SiDECLARA / SideClara**.

El código fuente vive en un repositorio privado. Este repositorio solo publica el instalador y las imágenes precompiladas.

## Instalación (Ubuntu)

```bash
curl -fsSL https://raw.githubusercontent.com/DTP-SESAJ/SiDECLARA-releases/main/sideclara-cli.sh | sudo bash
```

Luego: `sudo sideclara`

## Offline

Descargue de [Releases](https://github.com/DTP-SESAJ/SiDECLARA-releases/releases) los archivos:

- `sideclara-app-VERSION.tar.gz`
- `sideclara-bundle-VERSION.zip`

y ejecute:

```bash
sudo bash sideclara-cli.sh install-offline /ruta/a/la/carpeta
```

Versión publicada en `main`: ver archivo `VERSION`.
