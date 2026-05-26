# k3s-kustomize-ops

Repositori ini berisi skrip instalasi K3s multi-distro dan manifes Kubernetes yang dikelola dengan Kustomize untuk deployment ke berbagai lingkungan (development dan production).

---

## Daftar Isi

- [Prasyarat Sistem](#prasyarat-sistem)
- [Arsitektur Repositori](#arsitektur-repositori)
- [Arsitektur Kustomize](#arsitektur-kustomize)
- [Instalasi K3s](#instalasi-k3s)
- [Deploy Aplikasi](#deploy-aplikasi)
- [Verifikasi Kluster](#verifikasi-kluster)
- [Multi-Node Cluster](#multi-node-cluster)
- [Troubleshooting](#troubleshooting)
- [Uninstal](#uninstal)

---

## Prasyarat Sistem

### Sistem Operasi yang Didukung

| Distro Family | Distro | Versi Minimum |
|---|---|---|
| Debian | Debian | 11 (Bullseye) |
| | Ubuntu | 20.04 LTS |
| | Linux Mint | 20 |
| RHEL | RHEL / CentOS Stream | 8 |
| | Rocky Linux / AlmaLinux | 8 |
| Fedora | Fedora | 36+ |
| SUSE | openSUSE Leap | 15.4 |
| | SLES | 15 SP4 |
| Arch | Arch Linux / Manjaro | Rolling |
| Alpine | Alpine Linux | 3.17+ |

### Spesifikasi Hardware Minimum

| Komponen | Server Node | Agent Node |
|---|---|---|
| CPU | 2 core (x86_64, arm64, armv7l) | 1 core |
| RAM | 1 GB | 512 MB |
| Disk | 10 GB (SSD direkomendasikan) | 5 GB |

### Port Jaringan yang Diperlukan

Port berikut harus dapat diakses antar node dalam kluster:

| Port | Protokol | Arah | Deskripsi |
|---|---|---|---|
| `6443` | TCP | Server ← Agent/Client | Kubernetes API Server |
| `8472` | UDP | Server ↔ Agent | Flannel VXLAN (overlay network) |
| `10250` | TCP | Server ← Agent | Kubelet metrics (Prometheus scraping) |
| `51820` | UDP | Server ↔ Agent | WireGuard (opsional, jika diaktifkan) |
| `2379-2380` | TCP | Server ↔ Server | etcd (hanya multi-server HA mode) |

> Catatan: K3s menggunakan Flannel sebagai CNI default dengan transport VXLAN (UDP 8472). Port `6443/TCP` adalah satu-satunya port yang perlu diekspos ke client eksternal (kubectl).

### Dependensi yang Dipasang Otomatis

Skrip `install-k3s.sh` akan menginstal dependensi berikut jika belum tersedia:

- `curl` — mengunduh K3s installer
- `iptables` — manajemen firewall rules

---

## Arsitektur Repositori

```text
k3s-kustomize-ops/
├── README.md
├── scripts/
│   ├── install-k3s.sh        # Instalasi K3s multi-distro (server & agent)
│   └── uninstall-k3s.sh      # Uninstal K3s beserta data (opsional --purge)
└── kustomize/
    ├── base/                  # Manifes Kubernetes environment-agnostic
    │   ├── kustomization.yaml # Entry point Kustomize untuk base
    │   ├── deployment.yaml    # Deployment statis dengan resource minimum
    │   └── service.yaml       # Service ClusterIP untuk internal access
    └── overlays/
        ├── dev/               # Override untuk lingkungan development
        │   └── kustomization.yaml
        └── prod/              # Override untuk lingkungan production (HA)
            └── kustomization.yaml
```

---

## Arsitektur Kustomize

Kustomize bekerja dengan prinsip patching tanpa templating. Berbeda dengan Helm yang menggunakan template engine (`{{ .Values.replicas }}`), Kustomize melakukan *strategic merge patch* — yaitu menggabungkan dua dokumen YAML berdasarkan key yang sama.

### Bagaimana Overlay Bekerja

```
kustomize/base/deployment.yaml        kustomize/overlays/prod/kustomization.yaml
────────────────────────────          ──────────────────────────────────────────
spec:                                 patches:
  replicas: 1            ──────────►    - patch: |-
  containers:              (merge)           spec:
    - resources:                              replicas: 3   <-- override
        limits:                               containers:
          memory: "256Mi"                       - resources:
                                                    limits:
                                                      memory: "512Mi"  <-- override

                        Output Akhir (kubectl apply):
                        ─────────────────────────────
                        spec:
                          replicas: 3          <-- dari prod overlay
                          containers:
                            - resources:
                                limits:
                                  memory: "512Mi"  <-- dari prod overlay
```

### Pratinjau Output Kustomize

Selalu pratinjau manifes sebelum menjalankan `kubectl apply`:

```bash
# Pratinjau manifes yang akan di-deploy ke dev
kubectl kustomize kustomize/overlays/dev/

# Pratinjau manifes yang akan di-deploy ke prod
kubectl kustomize kustomize/overlays/prod/

# Dry-run tanpa benar-benar apply (memerlukan koneksi ke API server)
kubectl apply -k kustomize/overlays/prod/ --dry-run=client

# Lihat diff antara kondisi kluster saat ini dengan manifes baru
kubectl diff -k kustomize/overlays/prod/
```

---

## Instalasi K3s

### Persiapan Awal

```bash
# Clone repositori
git clone https://github.com/yourorg/k3s-kustomize-ops.git
cd k3s-kustomize-ops

# Beri izin eksekusi
chmod +x scripts/install-k3s.sh scripts/uninstall-k3s.sh
```

### Instalasi Server Node (Control Plane)

```bash
# Instalasi minimal dengan Traefik (default)
sudo ./scripts/install-k3s.sh

# Instalasi dengan NGINX Ingress (menonaktifkan Traefik)
sudo ./scripts/install-k3s.sh --ingress nginx

# Instalasi dengan TLS SAN untuk IP statis dan domain
sudo ./scripts/install-k3s.sh \
  --ingress nginx \
  --tls-san 192.168.1.10,k3s.example.com

# Menonaktifkan komponen bawaan tertentu
sudo ./scripts/install-k3s.sh \
  --disable servicelb,local-storage \
  --ingress nginx

# Dry-run: tampilkan konfigurasi tanpa mengeksekusi
sudo ./scripts/install-k3s.sh --ingress nginx --dry-run
```

### Instalasi Agent Node (Worker)

Setelah server node berjalan, ambil token dan daftarkan worker node:

```bash
# Di SERVER NODE: ambil token
sudo cat /var/lib/rancher/k3s/server/node-token

# Di WORKER NODE: jalankan skrip agent
sudo ./scripts/install-k3s.sh \
  --role agent \
  --server-url https://<IP_SERVER>:6443 \
  --token <TOKEN_DARI_SERVER>
```

### Referensi Opsi Lengkap

```
Opsi:
  --role        <server|agent>     Role node (default: server)
  --server-url  <URL>              URL K3s server (wajib untuk agent)
  --token       <TOKEN>            Token join cluster (wajib untuk agent)
  --disable     <komponen,...>     Komponen yang dinonaktifkan
                                   (traefik, servicelb, local-storage, metrics-server)
  --ingress     <nginx|traefik>    Ingress controller (default: traefik)
  --tls-san     <IP/domain,...>    SAN tambahan untuk sertifikat API server
  --data-dir    <path>             Direktori data K3s (default: /var/lib/rancher/k3s)
  --channel     <stable|latest>    Channel rilis K3s (default: stable)
  --dry-run                        Tampilkan konfigurasi tanpa mengeksekusi
  --help                           Tampilkan bantuan
```

---

## Deploy Aplikasi

### Deploy ke Development

```bash
# Apply manifes ke namespace 'dev'
kubectl apply -k kustomize/overlays/dev/

# Verifikasi
kubectl get all -n dev
```

### Deploy ke Production

```bash
# Lihat perubahan yang akan diterapkan
kubectl diff -k kustomize/overlays/prod/

# Apply manifes ke namespace 'production'
kubectl apply -k kustomize/overlays/prod/

# Monitor rollout
kubectl rollout status deployment/myapp -n production
```

### Update Image di Production

Edit field `newTag` di `kustomize/overlays/prod/kustomization.yaml`:

```yaml
images:
  - name: myapp
    newTag: "1.1.0"   # Perbarui versi di sini
```

Kemudian apply ulang:

```bash
kubectl apply -k kustomize/overlays/prod/
```

---

## Verifikasi Kluster

Jalankan perintah berikut setelah instalasi selesai untuk memastikan kluster berjalan dengan benar:

```bash
# Periksa status semua node
kubectl get nodes -o wide

# Periksa semua pod di semua namespace (pastikan semua Running/Completed)
kubectl get pods -A

# Informasi kluster (API server endpoint)
kubectl cluster-info

# Verifikasi resource yang tersedia di node
kubectl describe nodes

# Periksa events terbaru (berguna untuk debugging)
kubectl get events -A --sort-by='.lastTimestamp'
```

Output `kubectl get nodes` yang diharapkan:

```
NAME         STATUS   ROLES                  AGE   VERSION
my-server    Ready    control-plane,master   5m    v1.31.x+k3s1
my-worker1   Ready    <none>                 3m    v1.31.x+k3s1
```

---

## Multi-Node Cluster

### Topologi Rekomendasi

```
                    ┌─────────────────┐
     kubectl ──────►│  Server Node    │ :6443 (API)
                    │  (Control Plane)│
                    └────────┬────────┘
                             │ K3s token
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
       ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
       │ Agent Node 1│ │ Agent Node 2│ │ Agent Node 3│
       │  (Worker)   │ │  (Worker)   │ │  (Worker)   │
       └─────────────┘ └─────────────┘ └─────────────┘
              │ UDP 8472 (Flannel VXLAN) ─────────────│
```

### Menambah Worker Node

```bash
# 1. Di server: ambil token
sudo cat /var/lib/rancher/k3s/server/node-token

# 2. Di worker baru: instal sebagai agent
sudo ./scripts/install-k3s.sh \
  --role agent \
  --server-url https://192.168.1.10:6443 \
  --token K10abc123...

# 3. Di server: verifikasi node baru terdaftar
kubectl get nodes
```

---

## Troubleshooting

### Lokasi Log K3s

```bash
# Log service K3s (real-time)
sudo journalctl -u k3s -f

# Log agent K3s
sudo journalctl -u k3s-agent -f

# Log sistem (alternatif)
sudo tail -f /var/log/syslog           # Debian/Ubuntu
sudo tail -f /var/log/messages         # RHEL/CentOS/Fedora
sudo journalctl -xeu k3s --no-pager    # Semua distro systemd (verbose)

# Log pod dan container
ls /var/log/pods/
ls /var/log/containers/
```

### Masalah Umum

**Node tidak muncul di `kubectl get nodes`:**

```bash
# Periksa konektivitas ke API server dari agent
curl -k https://<SERVER_IP>:6443/readyz

# Periksa token yang digunakan agent
sudo journalctl -u k3s-agent | grep -i "token\|error\|fail"

# Verifikasi port 6443 terbuka di server
nc -zv <SERVER_IP> 6443
```

**Pod stuck di `ContainerCreating` atau `Pending`:**

```bash
# Lihat detail pod
kubectl describe pod <POD_NAME> -n <NAMESPACE>

# Periksa apakah image berhasil di-pull
kubectl get events -n <NAMESPACE> --sort-by='.lastTimestamp'
```

**Flannel tidak bisa berkomunikasi antar node:**

```bash
# Verifikasi port UDP 8472 tidak diblokir
sudo tcpdump -i any udp port 8472

# Periksa interface Flannel
ip addr show flannel.1
```

**K3s gagal start setelah reboot:**

```bash
# Periksa status service
sudo systemctl status k3s

# Lihat log error terakhir
sudo journalctl -u k3s -n 100 --no-pager

# Restart service secara manual
sudo systemctl restart k3s
```

### Informasi Debug Berguna

```bash
# Versi K3s yang terinstal
k3s --version

# Status komponen internal kluster
kubectl get componentstatuses 2>/dev/null || kubectl get cs

# Kapasitas dan alokasi resource per node (memerlukan metrics-server aktif)
kubectl top nodes

# Log container yang crash
kubectl logs <POD_NAME> -n <NAMESPACE> --previous

# Tail live log container
kubectl logs <POD_NAME> -n <NAMESPACE> -f
```

---

## Uninstal

### Uninstal Standar (mempertahankan data)

```bash
# Uninstal dengan deteksi role otomatis
sudo ./scripts/uninstall-k3s.sh

# Uninstal role spesifik
sudo ./scripts/uninstall-k3s.sh --role server
sudo ./scripts/uninstall-k3s.sh --role agent
```

### Uninstal Beserta Seluruh Data

```bash
# --purge menghapus /var/lib/rancher/k3s, volumes, dan kubeconfig
sudo ./scripts/uninstall-k3s.sh --purge --yes
```

> Peringatan: Flag `--purge` tidak dapat dibalik. Semua data persistent termasuk PersistentVolumes lokal akan dihapus secara permanen.

---

## Referensi

- [Dokumentasi Resmi K3s](https://docs.k3s.io)
- [Dokumentasi Kustomize](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [K3s GitHub Releases](https://github.com/k3s-io/k3s/releases)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)