#!/bin/bash

# Path Repository Pterodactyl
SERVER_REPO="/var/www/pterodactyl/app/Repositories/Eloquent/ServerRepository.php"
USER_REPO="/var/www/pterodactyl/app/Repositories/Eloquent/UserRepository.php"
TIMESTAMP=$(date -u +"%Y-%m-%d-%H-%M-%S")

echo "🚀 Memasang Proteksi Stealth View (Private Panel)..."

# --- 1. BACKUP & REPLACE SERVER REPOSITORY ---
if [ -f "$SERVER_REPO" ]; then
  mv "$SERVER_REPO" "${SERVER_REPO}.bak_${TIMESTAMP}"
  echo "📦 Backup ServerRepository dibuat."
fi

cat > "$SERVER_REPO" << 'EOF'
<?php

namespace Pterodactyl\Repositories\Eloquent;

use Illuminate\Support\Facades\Auth;
use Pterodactyl\Models\Server;
use Illuminate\Contracts\Pagination\LengthAwarePaginator;
use Pterodactyl\Contracts\Repository\ServerRepositoryInterface;

class ServerRepository extends EloquentRepository implements ServerRepositoryInterface
{
    /**
     * Return the model backing this repository.
     */
    public function model(): string
    {
        return Server::class;
    }

    /**
     * Return a paginated list of all servers.
     * 🔒 PROTECTED BY NOAHFORME
     */
    public function paginatedListData(int $perPage): LengthAwarePaginator
    {
        $user = Auth::user();
        $instance = $this->getBuilder()->with('node', 'user', 'allocation');

        // Jika bukan Admin ID 1, hanya tampilkan server miliknya
        if ($user && $user->id !== 1) {
            $instance->where('owner_id', $user->id);
        }

        return $instance->paginate($perPage);
    }
}
EOF

# --- 2. BACKUP & REPLACE USER REPOSITORY ---
if [ -f "$USER_REPO" ]; then
  mv "$USER_REPO" "${USER_REPO}.bak_${TIMESTAMP}"
  echo "📦 Backup UserRepository dibuat."
fi

cat > "$USER_REPO" << 'EOF'
<?php

namespace Pterodactyl\Repositories\Eloquent;

use Illuminate\Support\Facades\Auth;
use Pterodactyl\Models\User;
use Illuminate\Contracts\Pagination\LengthAwarePaginator;
use Pterodactyl\Contracts\Repository\UserRepositoryInterface;

class UserRepository extends EloquentRepository implements UserRepositoryInterface
{
    /**
     * Return the model backing this repository.
     */
    public function model(): string
    {
        return User::class;
    }

    /**
     * Return a paginated list of users.
     * 🔒 PROTECTED BY NOAHFORME
     */
    public function paginatedListData(int $perPage): LengthAwarePaginator
    {
        $user = Auth::user();
        $instance = $this->getBuilder()->withCount('servers');

        // Jika bukan Admin ID 1, hanya tampilkan dirinya sendiri
        if ($user && $user->id !== 1) {
            $instance->where('id', $user->id);
        }

        return $instance->paginate($perPage);
    }
}
EOF

# --- 3. SET PERMISSION & CLEAR CACHE ---
chmod 644 "$SERVER_REPO"
chmod 644 "$USER_REPO"

echo "🧹 Membersihkan cache panel..."
cd /var/www/pterodactyl && php artisan view:clear && php artisan cache:clear

echo "✅ Stealth Mode Berhasil Dipasang!"
echo "🔒 Hanya Admin ID 1 yang bisa melihat semua data."
echo "🛡️ User/Admin lain hanya bisa melihat data milik mereka sendiri."
