-- ─────────────────────────────────────────────────────────────
-- ms-security database
-- Convención: db_<servicio>  →  db_security
-- ─────────────────────────────────────────────────────────────
CREATE USER security_user WITH PASSWORD 'changeme_local';
CREATE DATABASE db_security OWNER security_user
    ENCODING 'UTF8'
    LC_COLLATE 'en_US.utf8'
    LC_CTYPE 'en_US.utf8'
    TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE db_security TO security_user;

\connect db_security

-- Extensiones requeridas por ms-security
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Permitir que security_user cree objetos en el schema public
GRANT ALL ON SCHEMA public TO security_user;

-- GUC parameter para RLS (Row-Level Security)
ALTER DATABASE db_security SET app.current_tenant = '';
