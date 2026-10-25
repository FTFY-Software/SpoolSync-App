import { PrismaClient } from '@prisma/client';
import bcrypt from 'bcryptjs';
import { ALL_PERMISSIONS, PERMISSION_GROUPS } from '../src/utils/permissions.js';

const prisma = new PrismaClient();

// Initial admin account; override via env (install.sh sets these).
const ADMIN_USERNAME = process.env.SEED_ADMIN_USERNAME || 'admin';
const ADMIN_EMAIL = process.env.SEED_ADMIN_EMAIL || 'admin@spoolsync.local';
const ADMIN_PASSWORD = process.env.SEED_ADMIN_PASSWORD || 'admin123';

const VIEW_PERMISSIONS = PERMISSION_GROUPS.flatMap((g) => g.permissions.filter((p) => p.endsWith(':view')));
const EDITOR_EXCLUDED = ['users:', 'roles:', 'settings:'];
const EDITOR_PERMISSIONS = ALL_PERMISSIONS.filter(
  (p) => !EDITOR_EXCLUDED.some((prefix) => p.startsWith(prefix))
);

async function main() {
  // ── Seed system roles ──────────────────────────────────────────────────────
  const adminRole = await prisma.customRole.upsert({
    where: { name: 'Administrator' },
    update: { permissions: ALL_PERMISSIONS, isSystem: true },
    create: {
      name: 'Administrator',
      description: 'Full access to all resources',
      permissions: ALL_PERMISSIONS,
      isSystem: true,
    },
  });

  await prisma.customRole.upsert({
    where: { name: 'Editor' },
    update: { permissions: EDITOR_PERMISSIONS },
    create: {
      name: 'Editor',
      description: 'Can create and edit most resources; no user/role/settings management',
      permissions: EDITOR_PERMISSIONS,
    },
  });

  await prisma.customRole.upsert({
    where: { name: 'Viewer' },
    update: { permissions: VIEW_PERMISSIONS },
    create: {
      name: 'Viewer',
      description: 'Read-only access to all resources',
      permissions: VIEW_PERMISSIONS,
    },
  });

  console.log('Seeded 3 default roles: Administrator, Editor, Viewer');

  // ── Seed admin user ────────────────────────────────────────────────────────
  const passwordHash = await bcrypt.hash(ADMIN_PASSWORD, 10);

  const admin = await prisma.user.upsert({
    where: { email: ADMIN_EMAIL },
    update: { isSuperAdmin: true },
    create: {
      username: ADMIN_USERNAME,
      email: ADMIN_EMAIL,
      passwordHash,
      isSuperAdmin: true,
      customRoles: { connect: [{ id: adminRole.id }] },
    },
  });

  console.log('Seeded admin user:', admin.email, '(isSuperAdmin: true)');
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
