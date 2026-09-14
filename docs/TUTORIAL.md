# Video recording guide / راهنمای ضبط آموزش

The terminal interface stays English. This file is a recording outline, not a published video.

## Demonstration sequence

1. Use two disposable Ubuntu/Debian servers. Explain which one initiates SSH.
2. Show the release tag and SHA256 verification before running the installer.
3. On the destination, select Foreign / Initial setup.
4. On the source, configure the destination and verify its fingerprint out of band.
5. Demonstrate automatic public-key installation. Do not record passwords or private keys.
6. Add `L|127.0.0.1:28888:127.0.0.1:28443`. Explain that the destination inbound must listen on 28443.
7. Show Diagnostics / 3x-ui setup guide. Route the source inbound to the source outbound at 127.0.0.1:28888.
8. Use the client's actual secure TLS/Reality configuration and verify the foreign egress IP.
9. Demonstrate Health check. Explain that a listener alone cannot prove an application's success.
10. Demonstrate Repair on a disposable setup with a deliberately invalid forward record.
11. For benchmarking, run `iperf3 -s -B 127.0.0.1 -p 5201` on the destination and add a separate local forward to it.
12. Label a benchmark `before`, enable optimization on both machines, reconnect, then repeat with `after`.
13. Compare throughput, retransmits and CPU. Do not promise a fixed percentage speed increase.
14. Show export/import and rollback. Explain that private keys and host trust are not included in forward exports.

## ترتیب پیشنهادی فارسی

راه‌اندازی خارج، اتصال ایران، نصب کلید، ساخت فوروارد، تنظیم 3x-ui، بررسی خروجی، تست سلامت، تعمیر آزمایشی، مقایسه سرعت و بازیابی تنظیمات را به همین ترتیب نشان بده.
برای توضیح مهم‌ترین باگ نسخه قدیمی، بگو شرط موفقیت SSH برعکس بود؛ تست‌های نسخه جدید نصب موفق و کلید خالی را جداگانه بررسی می‌کنند.

## Checklist for the description box

- Repository and a version-pinned release link
- Both server operating systems and test date
- Correct distinction between `-L` and `-R`
- Required ports and who initiates SSH
- Chapters for setup, 3x-ui, diagnostics, benchmark and rollback
- A link to Issues for logs with secrets removed
