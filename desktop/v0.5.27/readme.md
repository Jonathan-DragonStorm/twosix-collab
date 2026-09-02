# Instructions

sha256sum cosmonic-desktop-0.5.27-x64.tar.gz > original.sha256
split -b 50M cosmonic-desktop-0.5.27-x64.tar.gz cosmonic-desktop-0.5.27-x64.tar.gz.part_
cat cosmonic-desktop-0.5.27-x64.tar.gz.part_* > cosmonic-desktop-0.5.27-x64.tar.gz
sha256sum -c original.sha256
