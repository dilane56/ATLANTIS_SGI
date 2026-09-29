# ATLANTIS_SGI

Scripts de sauvegarde et de restauration de la base SQL Server `BD_ATLANTIS_SGI`.

## Arborescence

```
scripts/
├── installation/                  à exécuter une fois, dans l'ordre
│   ├── 01_Log_Database.sql        base Log_Database + tables de journalisation
│   ├── 02_usp_BackupDatabase.sql  procédure de sauvegarde FULL / DIFF / LOG
│   └── 03_Jobs_SQL_Agent.sql      jobs planifiés + alertes e-mail
├── full_backup/                   sauvegarde FULL manuelle (appel de la procédure)
├── diff_backup/                   sauvegarde DIFF manuelle
├── log_backup/                    sauvegarde LOG manuelle
└── restaure/
    ├── full_bd_restaure_script.sql         FULL seule
    ├── full_+_diff_restaure_script.sql     FULL + DIFF
    ├── full_diff_log_restaure_script.sql   FULL + DIFF + LOG, point dans le temps
    └── fast_restaure_db.sql                restauration rapide (dev / test uniquement)
```

Prérequis : SQL Server 2017 ou supérieur, SQL Server Agent démarré, Database Mail configuré.

Avant toute mise en production, dérouler le plan de tests : [PLAN_DE_TESTS.md](PLAN_DE_TESTS.md).

## Installation

1. Exécuter `scripts/installation/01_Log_Database.sql`. Si la table `BackupExecutionLog` existe déjà, les colonnes manquantes sont ajoutées sans perte de données.
2. Exécuter `scripts/installation/02_usp_BackupDatabase.sql`.
3. Dans `scripts/installation/03_Jobs_SQL_Agent.sql`, renseigner `@OperatorEmail` et `@MailProfile`, puis l'exécuter.
4. Redémarrer le service SQL Server Agent pour activer le profil Database Mail.
5. Lancer une première fois le job FULL. Les jobs DIFF et LOG échouent tant qu'aucune FULL n'existe :
   ```sql
   EXEC msdb.dbo.sp_start_job @job_name = N'ATLANTIS - Sauvegarde FULL - BD_ATLANTIS_SGI';
   ```

Le compte de service SQL Server doit avoir les droits d'écriture sur `C:\Backups\AtlantisBackup\`.

## Stratégie de sauvegarde

| Type | Planification | Rétention | Dossier |
|------|---------------|-----------|---------|
| FULL | dimanche 01h00 | 552 h (23 jours) | `C:\Backups\AtlantisBackup\FULL\` |
| DIFF | lundi à samedi 01h00 | 360 h (15 jours) | `C:\Backups\AtlantisBackup\DIFF\` |
| LOG | toutes les 15 minutes | 168 h (7 jours) | `C:\Backups\AtlantisBackup\LOG\` |

Les rétentions viennent du fichier `Politique de Retention.txt`.

- **Nommage** : `<Base>_yyyyMMdd_HHmmss_<TYPE>.bak|.trn`. L'ordre alphabétique correspond à l'ordre chronologique.
- **Contrôles** : chaque sauvegarde est faite avec `COMPRESSION` et `CHECKSUM`, puis vérifiée par `RESTORE VERIFYONLY WITH CHECKSUM`.
- **Purge** : après chaque sauvegarde réussie, les fichiers du même type plus anciens que la rétention sont supprimés.
  - Garde-fou : un fichier postérieur à la dernière FULL n'est jamais supprimé. Si les FULL échouent plusieurs jours, la chaîne de restauration reste complète.
  - Une sauvegarde `@CopyOnly = 1` ne déclenche pas de purge.
- **Journalisation** : chaque exécution est enregistrée dans `Log_Database.dbo.BackupExecutionLog` (statut, durée, taille, erreur, purge).
  - La sortie complète de chaque job est écrite dans `C:\Backups\AtlantisBackup\JobLogs\`. On y trouve tous les messages d'erreur SQL Server, y compris ceux qu'un `CATCH` T-SQL ne peut pas lire.
- **Alertes** : en cas d'échec d'un job, un e-mail est envoyé à l'opérateur `DBA_ATLANTIS` et l'événement est écrit dans le journal Windows.

### Objectifs de restauration

- **RPO (perte de données maximale)** : environ 15 minutes, soit l'intervalle entre deux sauvegardes LOG.
  - Si la base est endommagée mais que le serveur répond, la sauvegarde de fin de journal (tail-log) des scripts de restauration peut ramener cette perte à zéro.
  - Si le disque des sauvegardes est perdu avec le serveur, le RPO n'est plus garanti : voir « Points restant à traiter ».
- **Restauration à un instant précis** : possible sur les 6 derniers jours environ. Il faut les journaux produits depuis la DIFF précédant l'instant voulu, et les journaux sont conservés 7 jours.
- **RTO (durée de remise en service)** : à mesurer lors des tests de restauration. La durée de chaque restauration est enregistrée dans `RestoreExecutionLog.DurationSeconds`.

## Restauration

| Situation | Script |
|-----------|--------|
| Revenir à la dernière FULL | `full_bd_restaure_script.sql` |
| Revenir à la dernière nuit | `full_+_diff_restaure_script.sql` avec la FULL du dimanche et la DIFF de la nuit |
| Revenir à un instant précis / au plus près de l'incident | `full_diff_log_restaure_script.sql` avec la FULL, la dernière DIFF avant l'instant voulu, puis les journaux dans l'ordre et `@StopAt` |
| Copie rapide sur un poste de développement | `fast_restaure_db.sql` |

Déroulé commun aux trois scripts complets :
1. Vérification de tous les fichiers de sauvegarde, avant de toucher à la base.
2. Isolation de la base existante : sauvegarde de fin de journal dans `C:\Backups\AtlantisBackup\TAILLOG\` si possible, sinon mise hors ligne.
3. `WITH MOVE` optionnel : renseigner `@DataPath` / `@LogPath` pour restaurer sous un autre nom ou sur un autre serveur.
4. Restauration.
5. `DBCC CHECKDB`.
6. Recherche des utilisateurs orphelins.

En cas d'échec avant le début de la restauration, la base d'origine est remise en service automatiquement. Chaque restauration est enregistrée dans `Log_Database.dbo.RestoreExecutionLog`.

## Test de restauration périodique

Une sauvegarde n'est fiable que si sa restauration a été testée. Une fois par mois :

1. Ouvrir `full_diff_log_restaure_script.sql` et régler :
   - `@DatabaseName = 'BD_ATLANTIS_SGI_TEST'` ;
   - `@TailLogBackup = 0` ;
   - `@DataPath` / `@LogPath` vers un emplacement de test ;
   - les fichiers de la dernière chaîne FULL + DIFF + LOG.
2. Exécuter le script. `DBCC CHECKDB` est lancé automatiquement.
3. Relever la durée dans `RestoreExecutionLog` : c'est votre RTO réel.
4. Supprimer la base `BD_ATLANTIS_SGI_TEST`.

## Supervision

```sql
-- Dernière sauvegarde réussie par type
SELECT DatabaseName, BackupType, MAX(StartTime) AS DerniereReussie
FROM Log_Database.dbo.BackupExecutionLog
WHERE Status = 'SUCCESS'
GROUP BY DatabaseName, BackupType;

-- Échecs et exécutions interrompues (RUNNING) des 7 derniers jours
SELECT *
FROM Log_Database.dbo.BackupExecutionLog
WHERE Status <> 'SUCCESS'
  AND StartTime >= DATEADD(DAY, -7, GETDATE())
ORDER BY StartTime DESC;
```

## Points restant à traiter

- **Copie hors serveur** : les sauvegardes restent sur `C:\` du serveur. Une copie vers un autre disque ou partage, idéalement hors site, est indispensable (règle 3-2-1).
- **Chiffrement** des sauvegardes (`WITH ENCRYPTION`) si les données sont sensibles. Il faut alors sauvegarder le certificat séparément.
- **Dossier `TAILLOG\`** : il n'est pas purgé automatiquement. Supprimer ses fichiers une fois la restauration validée.
- **Bases Sage compta et Sage paie** : elles figurent dans la politique de rétention. La procédure `usp_BackupDatabase` peut les sauvegarder aussi : il suffit d'ajouter leurs jobs.
