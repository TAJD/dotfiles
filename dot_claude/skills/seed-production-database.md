# Seed Production Database

## Overview

Seeds a production database with demo data when running an OTP release where Mix is not available and `bin/app eval` creates isolated VM instances that conflict with the running application.

## The Problem

Standard seeding approaches fail in production releases:

1. **Mix not available**: `mix run priv/repo/seeds.exs` fails because Mix is a build-time tool
2. **`bin/app eval` conflicts**: Creates a NEW Erlang VM instance that:
   - Tries to start the full application
   - Conflicts with the already-running app (port binding errors)
   - Lacks full application context (telemetry ETS tables not initialized)
3. **RPC requires distributed Erlang**: Not configured by default in releases

## Solution: Export from Dev, Import via SQL

### Step 1: Seed Local Database

```bash
cd backend

# Clear existing data
docker exec rovikore-postgres psql -U postgres -d rovikore_host_dev -c \
  "TRUNCATE merchants, users, merchant_roles, sites, categories, products, product_variants, orders, order_items, discount_codes CASCADE;"

# Run seeds
mix run priv/repo/seeds.exs
```

### Step 2: Export Demo Data

```bash
cd backend

# Export tables as SQL with column inserts
docker exec rovikore-postgres pg_dump -U postgres -d rovikore_host_dev \
  --data-only \
  --table=merchants \
  --table=users \
  --table=merchant_roles \
  --table=sites \
  --table=categories \
  --table=products \
  --table=product_variants \
  --table=orders \
  --table=order_items \
  --table=discount_codes \
  --column-inserts \
  > ../seed_production_data.sql
```

**Note**: You'll see a warning about circular foreign keys (categories table) - this is expected and handled in import.

### Step 3: Copy to Production Server

```bash
# Copy to server
scp -i ~/.ssh/rovikore_deploy seed_production_data.sql root@<PROD_SERVER_IP>:/tmp/

# Copy into postgres container
ssh -i ~/.ssh/rovikore_deploy root@<PROD_SERVER_IP> \
  "docker cp /tmp/seed_production_data.sql rovicore-postgres:/tmp/seed_production_data.sql"
```

### Step 4: Load into Production Database

```bash
ssh -i ~/.ssh/rovikore_deploy root@<PROD_SERVER_IP> "docker exec -i rovicore-postgres psql -U rovikore -d rovikore_prod << 'EOF'
BEGIN;
-- Truncate all tables (handles circular foreign keys automatically)
TRUNCATE merchants, users, merchant_roles, sites, categories, products, product_variants, orders, order_items, discount_codes CASCADE;

-- Load data
\i /tmp/seed_production_data.sql

COMMIT;
EOF"
```

### Step 5: Verify

```bash
ssh -i ~/.ssh/rovikore_deploy root@<PROD_SERVER_IP> "docker exec rovicore-postgres psql -U rovikore -d rovikore_prod -c '
SELECT
  (SELECT COUNT(*) FROM merchants) as merchants,
  (SELECT COUNT(*) FROM users) as users,
  (SELECT COUNT(*) FROM sites) as sites,
  (SELECT COUNT(*) FROM categories) as categories,
  (SELECT COUNT(*) FROM products) as products,
  (SELECT COUNT(*) FROM product_variants) as variants,
  (SELECT COUNT(*) FROM orders) as orders,
  (SELECT COUNT(*) FROM discount_codes) as discount_codes;
'"
```

## Alternative Approaches That Don't Work

### ❌ Option 1: RPC to Running Node
```bash
bin/rovikore_host rpc 'Code.eval_file("/path/to/seeds.exs")'
```
**Why it fails**: Requires RELEASE_NODE and RELEASE_COOKIE environment variables. Distributed Erlang not configured by default in Docker releases.

### ❌ Option 2: Direct Eval
```bash
bin/rovikore_host eval 'Code.eval_file("/path/to/seeds.exs")'
```
**Why it fails**:
- Creates isolated VM instance
- `Application.ensure_all_started(:app)` conflicts with running app (port 4000 already in use)
- Missing telemetry ETS tables and application context

### ❌ Option 3: Remote Console
```bash
bin/rovikore_host remote
```
**Why it fails**: Connection refused - distributed Erlang not configured

## When to Use This Skill

- Initial production deployment with demo data
- Restoring production database from development state
- Testing production environment with realistic data
- Any scenario where Mix is unavailable but you need to populate the database

## Related Files

- **Seeds**: `backend/priv/repo/seeds.exs` - full demo dataset definition
- **Minimal seed**: Can create simplified version for essential data only

## Common Issues

**Issue**: "Seed data already exists. Skipping."
**Solution**: The seeds file checks for existing data. Clear the database first with TRUNCATE.

**Issue**: Circular foreign key constraint warnings
**Solution**: Expected for categories table with parent_id. TRUNCATE CASCADE handles this automatically.

**Issue**: Missing variants/discount codes in export
**Solution**: If local seeds didn't create them (API issues), they won't be in the export. Fix the seeds file first (see related bead).

## Production Credentials

After seeding, demo users have password `password123!`:
- admin@rovikore.local (platform admin)
- warehouse@rovikore.local (warehouse staff)
- alice@greenleaf-goods.co.uk (merchant)
- dave@greenleaf-goods.co.uk (merchant with limited role)
