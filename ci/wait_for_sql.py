"""
Attend que l'instance SQL Server soit prête à accepter des connexions.
Utilisé par le workflow CI (.github/workflows/test-pipeline.yml) — extrait
dans un fichier séparé plutôt qu'imbriqué en ligne dans le YAML, pour éviter
les problèmes d'indentation/quoting propres aux blocs multi-lignes en YAML.

Variables d'environnement attendues :
    SQL_SERVER   (défaut: localhost)
    SQL_PORT     (défaut: 1433)
    SQL_USER     (défaut: sa)
    SQL_PASSWORD (obligatoire)
"""

import os
import sys
import time

import pymssql

SERVER = os.environ.get("SQL_SERVER", "localhost")
PORT = os.environ.get("SQL_PORT", "1433")
USER = os.environ.get("SQL_USER", "sa")
PASSWORD = os.environ["SQL_PASSWORD"]
MAX_ATTEMPTS = 20
DELAY_SECONDS = 5

for attempt in range(1, MAX_ATTEMPTS + 1):
    try:
        conn = pymssql.connect(server=SERVER, port=PORT, user=USER, password=PASSWORD, database="master")
        conn.close()
        print("SQL Server est prêt.")
        sys.exit(0)
    except Exception as exc:
        print(f"En attente de SQL Server... ({attempt}/{MAX_ATTEMPTS}) — {exc}")
        time.sleep(DELAY_SECONDS)

print(f"SQL Server n'a pas démarré après {MAX_ATTEMPTS * DELAY_SECONDS} secondes.")
sys.exit(1)
