# Instructions

- sha256sum cosmonic-desktop-0.5.27-x64-airgap.tar.gz > cosmonic-desktop-0.5.27-x64-airgap.tar.gz.sha256
- split -b 50M cosmonic-desktop-0.5.27-x64-airgap.tar.gz cosmonic-desktop-0.5.27-x64-airgap.tar.gz.part_
- cat cosmonic-desktop-0.5.27-x64-airgap.tar.gz.part_* > cosmonic-desktop-0.5.27-x64-airgap.tar.gz
- sha256sum -c cosmonic-desktop-0.5.27-x64-airgap.tar.gz.sha256

# Installation

The `draft-install.sh` should be copied to the unzipped directory and run from there.  Still under testing.
