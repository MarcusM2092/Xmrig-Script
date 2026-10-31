The script starts by detecting the system package manager to install required build tools and libraries like cmake, gcc, and openssl.
It then creates a working directory at /root/moneroocean and clones the official XMRig source code repository there.
Next, it compiles XMRig from source with hardware support enabled and moves the compiled binary into the working directory.
It generates a configuration file containing the specified MoneroOcean pool address, wallet, and CPU optimization settings.
A systemd service file is then created to manage the miner, configured to run as root with automatic restarts.
Finally, the script reloads systemd, enables and starts the service, and displays the command to check its operational status.
