all: overlay_mount overlay_umount mock_cache_umount mock_cache_unlock mock_tmpfs_umount mock_tmpfs_mount

clean:
	rm -rf overlay_mount overlay_umount mock_cache_umount mock_cache_unlock mock_tmpfs_umount mock_tmpfs_mount

mock_tmpfs_mount: mock_tmpfs_mount.c
	gcc -o mock_tmpfs_mount mock_tmpfs_mount.c

mock_tmpfs_umount: mock_tmpfs_umount.c
	gcc -o mock_tmpfs_umount mock_tmpfs_umount.c

overlay_mount: overlay_mount.c
	gcc -o overlay_mount overlay_mount.c

overlay_umount: overlay_umount.c
	gcc -o overlay_umount overlay_umount.c

mock_cache_umount: mock_cache_umount.c
	gcc -o mock_cache_umount mock_cache_umount.c

mock_cache_unlock: mock_cache_unlock.c
	gcc -o mock_cache_unlock mock_cache_unlock.c

install: all
	install --owner=root --group=root --mode=6755 overlay_mount overlay_umount mock_cache_umount mock_cache_unlock mock_tmpfs_umount mock_tmpfs_mount /usr/bin
	install --owner=root --group=root --mode=0744 overlay_mount.sh overlay_umount.sh mock_cache_umount.sh mock_cache_unlock.sh mock_tmpfs_umount.sh mock_tmpfs_mount.sh /usr/bin
