# Ubuntu Kiosk ISO Builder with Docker Support

This script automates the creation of a custom Ubuntu 24.04 ISO designed for Kiosk applications. It features a lightweight Openbox environment, a pre-loaded Docker container, and a robust fallback mechanism.

## Configuration (Constants)

The following variables at the top of the script control the build configuration. You can edit them directly in `ubuntu-iso-with-nginx.sh`:

| Variable | Description | Default |
|----------|-------------|---------|
| `KIOSK_URL` | The main URL to display (Target Application). | `http://127.0.0.1:8090` |
| `DEFAULT_URL` | The fallback URL (Nginx) displayed while loading. | `http://127.0.0.1:80` |
| `DOCKER_IMAGE` | The Docker image to pre-load into the ISO. | `bomeravi/go-app-test` |
| `DOCKER_PORT` | The internal port the Docker container listens on. | `8090` |
| `KIOSK_MODE` | Default boot mode (`chrome` or `terminal`). | `terminal` |
| `ISO_NAME` | Name of the output ISO file. | `ubuntu-24.04-kiosk-docker` |

## Build Flow

The script executes the following steps to generate the ISO:

1.  **Preparation**: Installs build dependencies (`xorriso`, `debootstrap`, etc.) and sets up caching directories (`iso-cache/`) to speed up future repeated builds.
2.  **Base System**: Uses `debootstrap` to fetch and create a minimal Ubuntu 24.04 root filesystem.
3.  **System Configuration (Chroot)**:
    *   **Packages**: Installs X11, Openbox, Docker, Google Chrome, and Nginx.
    *   **User**: Creates the `kiosk` user with auto-login enabled.
    *   **Docker**: Pulls (or loads from cache) the specified `DOCKER_IMAGE` so the ISO works offline.
    *   **Permissions**: Adds `kiosk` user to the `docker` group.
4.  **Kiosk Logic Setup**:
    *   Creates the `autostart` script that manages the browser lifecycle.
    *   Configures Nginx "System Loading" page.
    *   Installs the `install-to-disk.sh` utility.
5.  **Assembly**:
    *   Compresses the filesystem into a SquashFS image.
    *   Generates EFI boot images for UEFI support.
    *   Builds the final bootable ISO using `xorriso`.

## Runtime Logic (How it works on boot)

When the Kiosk boots:

1.  **Auto-login**: LightDM automatically logs in the `kiosk` user.
2.  **Openbox Starts**: The window manager launches and executes `~/.config/openbox/autostart`.
3.  **Phase 1 - Immediate Feedback**:
    *   The script checks if the Docker app is ready (`curl $KIOSK_URL`).
    *   If NOT ready, it launches Nginx (serving "System Loading") and opens Chrome pointing to `DEFAULT_URL` ($DEFAULT_URL).
4.  **Phase 2 - Background Monitor**:
    *   A background process (`monitor_docker`) polls the Docker application every **1 second**.
    *   It prints status to `/home/kiosk/kiosk.log`.
5.  **Phase 3 - Dynamic Switch**:
    *   Once the Docker app responds, the Monitor kills the current Chrome instance.
    *   The main "Keep-Alive" loop detects the exit, re-evaluates the URL, sees Docker is up, and relaunches Chrome pointing to the real app (`$KIOSK_URL`).

## Installation to Hard Disk

The ISO includes a built-in installer for permanent deployment:

1.  Boot the ISO (default mode is Terminal).
2.  Run the installer from the menu (Option 0) or manually:
    ```bash
    sudo install-to-disk.sh
    ```
3.  Select target disk. The script creates partitions (EFI + Root), formats them, and copies the live system.

## Troubleshooting

Logs are located at:
*   `/home/kiosk/kiosk.log`: Main Kiosk startup and Monitor logs.
*   `/home/kiosk/chrome.log`: Chrome standard output/error.
