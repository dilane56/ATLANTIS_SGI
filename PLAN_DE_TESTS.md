# Plan de tests — sauvegarde et restauration ATLANTIS_SGI

Tests à réaliser **sur une instance de test** avant la mise en production des scripts du dépôt.
Pour chaque test : suivre les étapes, comparer au résultat attendu, cocher la case et noter les écarts dans la colonne « Remarques » du récapitulatif final.

---

## 0. Préparation de l'environnement de test

- [ ] **P1 — Instance de test** : SQL Server 2017 ou supérieur, SQL Server Agent démarré, même édition et même compte de service qu'en production si possible.
- [ ] **P2 — Copie de la base** : restaurer une sauvegarde récente de production sous le nom `BD_ATLANTIS_SGI` (mode de récupération FULL).
- [ ] **P3 — Base de test légère** pour les cas d'erreur :
  ```sql
  CREATE DATABASE BD_TEST_SAUVEGARDE;
  ALTER DATABASE BD_TEST_SAUVEGARDE SET RECOVERY FULL;
  GO
  USE BD_TEST_SAUVEGARDE;
  CREATE TABLE dbo.Marqueur (Id INT IDENTITY PRIMARY KEY, Libelle NVARCHAR(100), DateHeure DATETIME DEFAULT GETDATE());
  ```
- [ ] **P4 — Database Mail** : un profil opérationnel existe. Envoyer un e-mail de test et vérifier sa réception :
  ```sql
  EXEC msdb.dbo.sp_send_dbmail @profile_name = N'<profil>', @recipients = N'<adresse>', @subject = N'Test Database Mail', @body = N'OK';
  ```
- [ ] **P5 — Droits disque** : le compte de service SQL Server peut créer des dossiers et écrire dans `C:\Backups\AtlantisBackup\`.

---

## 1. Installation

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| I1 | Création de la journalisation | Exécuter `01_Log_Database.sql` sur une instance sans `Log_Database` | Base créée en mode SIMPLE, tables `BackupExecutionLog` et `RestoreExecutionLog` créées, index créé | ☐ |
| I2 | Ré-exécution | Exécuter `01_Log_Database.sql` une 2ᵉ fois | Aucune erreur, aucune donnée perdue | ☐ |
| I3 | Mise à niveau d'une table existante | Sur une instance qui possède l'ancienne `BackupExecutionLog` (avec des lignes), exécuter `01_Log_Database.sql` | Colonnes `ServerName`, `BackupSizeMB`, `CompressedSizeMB`, `ErrorNumber`, `PurgeInfo` ajoutées ; `BackupType` fait au moins 20 caractères ; anciennes lignes intactes | ☐ |
| I4 | Procédure | Exécuter `02_usp_BackupDatabase.sql` deux fois | Procédure créée puis remplacée sans erreur (`CREATE OR ALTER`) | ☐ |
| I5 | Jobs | Renseigner `@OperatorEmail` / `@MailProfile` dans `03_Jobs_SQL_Agent.sql`, l'exécuter | Opérateur `DBA_ATLANTIS` créé, 3 jobs créés, message « Profil Database Mail associé » | ☐ |
| I6 | Ré-exécution des jobs | Exécuter `03_Jobs_SQL_Agent.sql` une 2ᵉ fois | Jobs supprimés puis recréés, pas de doublon dans `msdb.dbo.sysjobs` ni `msdb.dbo.sysschedules` | ☐ |
| I7 | Profil mail absent | Exécuter `03` avec un `@MailProfile` inexistant | Avertissement « Profil Database Mail introuvable », jobs quand même créés | ☐ |
| I8 | Redémarrage SQL Agent | Redémarrer le service SQL Server Agent | Propriétés de SQL Agent > Système d'alerte : profil Database Mail activé | ☐ |

Vérification des plannings (I5) :
```sql
SELECT j.name, s.freq_type, s.freq_interval, s.freq_subday_type, s.freq_subday_interval, s.active_start_time
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
WHERE j.name LIKE N'ATLANTIS - Sauvegarde%';
-- Attendu : FULL 8/1/1/0/10000, DIFF 8/126/1/0/10000, LOG 4/1/4/15/0
```

---

## 2. Sauvegardes — cas nominaux

Requête de contrôle utilisée dans cette section :
```sql
SELECT TOP (5) * FROM Log_Database.dbo.BackupExecutionLog ORDER BY Id DESC;
```

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| S1 | FULL | Exécuter `full_backup/Atalantis_SGI_Full_Backup_Script.sql` | Fichier `FULL\BD_ATLANTIS_SGI_yyyyMMdd_HHmmss_FULL.bak` créé ; ligne `FULL` / `SUCCESS` avec durée, `BackupSizeMB`, `CompressedSizeMB`, `ServerName` et `PurgeInfo` renseignés | ☐ |
| S2 | DIFF | Exécuter `diff_backup/...DIFF_BACKUP_Script.sql` | Fichier `DIFF\..._DIFF.bak` ; ligne `DIFFERENTIAL` / `SUCCESS` | ☐ |
| S3 | LOG | Exécuter `log_backup/...Log_backup_Script.sql` | Fichier `LOG\..._LOG.trn` ; ligne `LOG` / `SUCCESS` | ☐ |
| S4 | Dossiers absents | Renommer `C:\Backups\AtlantisBackup\` puis relancer S1 | Dossiers `FULL\` recréés automatiquement, sauvegarde réussie | ☐ |
| S5 | Sauvegarde ponctuelle COPY_ONLY | Relever `differential_base_lsn` (requête ci-dessous), exécuter le script FULL avec `@CopyOnly = 1`, relever à nouveau | Ligne `FULL_COPY_ONLY` ; `differential_base_lsn` **inchangé** ; `PurgeInfo` vide (pas de purge) | ☐ |
| S6 | Checksums | Pour un fichier produit : `RESTORE HEADERONLY FROM DISK = '<fichier>'` | Colonne `HasBackupChecksums = 1` pour FULL, DIFF et LOG | ☐ |
| S7 | Sauvegardes simultanées | Lancer une FULL et, pendant son exécution, une LOG dans une autre session | Les deux réussissent | ☐ |

```sql
-- S5 : base des différentielles
SELECT differential_base_lsn, differential_base_time
FROM sys.master_files WHERE database_id = DB_ID('BD_ATLANTIS_SGI') AND file_id = 1;
```

---

## 3. Sauvegardes — cas d'erreur

Chaque test doit se terminer par une **erreur remontée** (message rouge dans SSMS) et, sauf mention contraire, une ligne `FAILED` avec `ErrorNumber` et `ErrorMessage` renseignés.

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| E1 | Type invalide | `EXEC Log_Database.dbo.usp_BackupDatabase @DBName = N'BD_ATLANTIS_SGI', @BackupType = 'XXX', @BackupRoot = N'C:\Backups\AtlantisBackup\';` | Erreur 50000 « Paramètre @BackupType invalide » ; **pas** de ligne de log (validation préalable) | ☐ |
| E2 | COPY_ONLY hors FULL | Même appel avec `@BackupType = 'DIFF', @CopyOnly = 1` | Erreur 50000 ; pas de ligne de log | ☐ |
| E3 | Base inexistante | `@DBName = N'BASE_INEXISTANTE', @BackupType = 'FULL'` | Erreur 50001 ; ligne `FAILED` | ☐ |
| E4 | Base hors ligne | `ALTER DATABASE BD_TEST_SAUVEGARDE SET OFFLINE;` puis FULL sur cette base ; remettre `ONLINE` ensuite | Erreur 50001 | ☐ |
| E5 | DIFF sans FULL | Sur `BD_TEST_SAUVEGARDE` neuve (jamais sauvegardée) : `@BackupType = 'DIFF'` | Erreur 50002 « Aucune sauvegarde FULL de base » | ☐ |
| E6 | LOG en mode SIMPLE | `ALTER DATABASE BD_TEST_SAUVEGARDE SET RECOVERY SIMPLE;` puis `@BackupType = 'LOG'` ; remettre en FULL ensuite | Erreur 50003 | ☐ |
| E7 | LOG sans FULL | Base FULL jamais sauvegardée (recréer `BD_TEST_SAUVEGARDE`) : `@BackupType = 'LOG'` | Erreur 50004 « Aucune sauvegarde FULL n'a initialisé la chaîne » | ☐ |
| E8 | Chemin inaccessible | `@BackupRoot = N'Z:\Inexistant\'` (lecteur absent) | Erreur (xp_create_subdir ou BACKUP) ; ligne `FAILED` | ☐ |
| E9 | Échec de la journalisation | Créer un déclencheur qui refuse l'insertion (ci-dessous), lancer une FULL, puis supprimer le déclencheur | Message « Avertissement : journalisation indisponible » ; **la sauvegarde est réalisée** (fichier présent) ; aucune erreur remontée | ☐ |
| E10 | Table de log absente | Renommer la table : `EXEC Log_Database.sys.sp_rename 'dbo.BackupExecutionLog', 'BackupExecutionLog_tmp';`, lancer une FULL, puis renommer à l'inverse | Message « Avertissement : journalisation indisponible - Invalid object name… » ; **la sauvegarde est réalisée** (fichier présent) ; aucune erreur remontée | ☐ |

```sql
-- E9 : simulation d'une panne d'écriture dans le log
USE Log_Database;
GO
CREATE TRIGGER dbo.TR_Test_RefusInsert ON dbo.BackupExecutionLog INSTEAD OF INSERT
AS THROW 50099, 'Test : insertion refusée', 1;
GO
-- ... lancer la sauvegarde FULL ...
DROP TRIGGER dbo.TR_Test_RefusInsert;
```

---

## 4. Purge et rétention

La purge s'appuie sur la date inscrite dans les fichiers de sauvegarde : on la teste avec `@RetentionHours = 0` plutôt qu'en attendant des jours.

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| R1 | Purge des FULL | Faire 2 FULL (`@RetentionHours = NULL`), puis une 3ᵉ avec `@RetentionHours = 0` | Les 2 premières FULL sont supprimées, la 3ᵉ est conservée ; `PurgeInfo` renseigné | ☐ |
| R2 | Garde-fou dernière FULL | FULL → LOG (a) → LOG (b) → FULL → LOG (c) → LOG (d) avec `@BackupType = 'LOG', @RetentionHours = 0` | (a) et (b) supprimés ; (c) et (d) conservés : rien de postérieur à la dernière FULL n'est supprimé | ☐ |
| R3 | Isolation des dossiers | Pendant R1, vérifier `DIFF\` et `LOG\` | Aucun fichier supprimé hors du dossier du type purgé | ☐ |
| R4 | Fichiers étrangers | Déposer un fichier `test.txt` et un `.bak` qui n'est pas une sauvegarde (fichier texte renommé) dans `FULL\`, relancer R1 | Les deux fichiers sont conservés (seules les vraies sauvegardes sont purgées) | ☐ |
| R5 | Échec de purge | `@RetentionHours = 0` avec le dossier `FULL\` en lecture seule pour le compte de service | Sauvegarde `SUCCESS`, `PurgeInfo` commence par « Échec de la purge » ou fichiers conservés — **la sauvegarde ne doit pas échouer** | ☐ |
| R6 | Rétention réelle | Après 8 jours de fonctionnement des jobs | Plus aucun `.trn` de plus de 168 h dans `LOG\` (hors garde-fou) | ☐ |

---

## 5. Jobs SQL Agent et alertes

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| J1 | Exécution manuelle | `EXEC msdb.dbo.sp_start_job N'ATLANTIS - Sauvegarde FULL - BD_ATLANTIS_SGI';` puis DIFF puis LOG | Historique du job en succès ; ligne `SUCCESS` dans le log | ☐ |
| J2 | Fichier de sortie | Ouvrir `C:\Backups\AtlantisBackup\JobLogs\BD_ATLANTIS_SGI_FULL.txt` | Contient la sortie complète (progression STATS, messages PRINT) | ☐ |
| J3 | Alerte e-mail en cas d'échec | Mettre `BD_ATLANTIS_SGI` hors ligne *sur l'instance de test*, lancer le job LOG, remettre en ligne | Job en échec, **e-mail reçu** par l'opérateur, événement dans le journal d'applications Windows | ☐ |
| J4 | Détail de l'erreur | Dans J3, consulter le fichier `JobLogs\..._LOG.txt` | Tous les messages d'erreur SQL Server y figurent (pas seulement le dernier) | ☐ |
| J5 | Planification réelle | Laisser tourner 24 h | ~96 lignes LOG, 1 DIFF (ou 1 FULL le dimanche) dans `BackupExecutionLog`, aucune ligne restée `RUNNING` | ☐ |
| J6 | Dimanche | Vérifier le lundi matin | FULL exécutée le dimanche à 01h00, pas de DIFF le dimanche | ☐ |

---

## 6. Restauration

Pour ne pas écraser la copie de travail, les tests se font de préférence sous le nom `BD_ATLANTIS_SGI_TEST`, avec `@DataPath` / `@LogPath` renseignés (dossier de test). Requête de contrôle :
```sql
SELECT TOP (5) * FROM Log_Database.dbo.RestoreExecutionLog ORDER BY Id DESC;
```

### 6.1 Cas nominaux

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| T1 | FULL seule vers un autre nom | `full_bd_restaure_script.sql` : `@DatabaseName = 'BD_ATLANTIS_SGI_TEST'`, `@TailLogBackup = 0`, `@DataPath` / `@LogPath` renseignés | Base créée, fichiers dans les dossiers indiqués (`sys.master_files`), CHECKDB sans erreur, ligne `FULL` / `SUCCESS` | ☐ |
| T2 | Écrasement d'une base existante | Relancer T1 (la base existe maintenant) avec `@TailLogBackup = 0` | Message « Base mise hors ligne », restauration réussie | ☐ |
| T3 | FULL + DIFF | `full_+_diff_restaure_script.sql` avec la FULL et une DIFF de la même chaîne | Succès ; les données de la DIFF sont présentes | ☐ |
| T4 | Point dans le temps | Voir scénario ci-dessous | Le marqueur « avant » est présent, le marqueur « après » est absent | ☐ |
| T5 | FULL + LOG sans DIFF | `full_diff_log_restaure_script.sql` avec `@BackupFilePathDIFF = NULL` | Succès, `RestoreType = 'FULL+LOG'` | ☐ |
| T6 | Connexions actives | Ouvrir une session SSMS sur la base cible (`USE BD_ATLANTIS_SGI_TEST`), puis lancer T2 | Session déconnectée, restauration réussie | ☐ |
| T7 | Utilisateurs orphelins | Voir scénario ci-dessous | Utilisateur listé dans la grille ; la commande proposée le corrige | ☐ |
| T8 | Restauration rapide | `fast_restaure_db.sql` vers une base de test | Succès, base en MULTI_USER | ☐ |

**Scénario T4 — point dans le temps**, sur `BD_TEST_SAUVEGARDE` :
```sql
-- 1. FULL de BD_TEST_SAUVEGARDE via la procédure
INSERT INTO BD_TEST_SAUVEGARDE.dbo.Marqueur (Libelle) VALUES (N'avant');
-- 2. attendre 1 minute, noter l'heure H = GETDATE()
WAITFOR DELAY '00:01:00';
SELECT GETDATE() AS H;
WAITFOR DELAY '00:01:00';
INSERT INTO BD_TEST_SAUVEGARDE.dbo.Marqueur (Libelle) VALUES (N'après');
-- 3. sauvegarde LOG via la procédure
-- 4. full_diff_log_restaure_script.sql : @DatabaseName = 'BD_TEST_SAUVEGARDE', @BackupFilePathDIFF = NULL,
--    journal = le .trn de l'étape 3, @StopAt = H, @TailLogBackup = 0
SELECT * FROM BD_TEST_SAUVEGARDE.dbo.Marqueur;   -- attendu : seulement 'avant'
```

**Scénario T7 — utilisateurs orphelins** :
```sql
CREATE LOGIN test_orphelin WITH PASSWORD = 'Test_Orphelin_2026!';
USE BD_TEST_SAUVEGARDE; CREATE USER test_orphelin FOR LOGIN test_orphelin;
-- FULL de BD_TEST_SAUVEGARDE, puis :
USE master; DROP LOGIN test_orphelin;
CREATE LOGIN test_orphelin WITH PASSWORD = 'Test_Orphelin_2026!';   -- nouveau SID
-- restaurer la FULL : test_orphelin doit apparaître dans la grille ; exécuter la commande proposée
```

### 6.2 Sauvegarde de fin de journal (tail-log)

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| T9 | Tail-log sans perte | Sur `BD_TEST_SAUVEGARDE` (FULL + LOG existants) : insérer un marqueur « tail », **ne pas** sauvegarder le journal, lancer `full_diff_log_restaure_script.sql` sur la même base avec `@TailLogBackup = 1` | Fichier `TAILLOG\..._TAILLOG.trn` créé et affiché ; restauration réussie | ☐ |
| T10 | Rejeu du tail-log | Relancer la restauration en ajoutant le fichier tail-log de T9 en dernier dans la liste des journaux (`@TailLogBackup = 0`) | Le marqueur « tail » est présent : **aucune perte de données** | ☐ |
| T11 | Tail-log impossible | `BD_TEST_SAUVEGARDE` en mode SIMPLE, `@TailLogBackup = 1` | Avertissement « Tail-log impossible », base mise hors ligne puis restaurée | ☐ |

### 6.3 Cas d'erreur

Chaque test doit remonter une erreur, afficher l'étape en échec et produire une ligne `FAILED` avec `FailedStep`.

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| T12 | Fichier introuvable | Chemin de DIFF erroné | Échec à l'ÉTAPE 1 ; la base cible **n'est pas modifiée**, reste ONLINE et MULTI_USER | ☐ |
| T13 | Fichier corrompu | Copier un `.bak`, en tronquer la fin (ou le remplacer par un fichier texte), l'utiliser | Échec à l'ÉTAPE 1 ; base non modifiée | ☐ |
| T14 | Échec après tail-log | Avec `@TailLogBackup = 1`, `@DataPath = 'Z:\Inexistant\'` | Échec à l'ÉTAPE 4 (restauration commencée) : message « Base en état RESTORING… » ; le chemin du tail-log est affiché | ☐ |
| T15 | DIFF d'une autre chaîne | FULL (A) → DIFF (x) → FULL (B) ; restaurer FULL (B) + DIFF (x) | Erreur SQL Server 3136 à l'ÉTAPE 5 ; message de reprise affiché | ☐ |
| T16 | Journaux dans le désordre | Lister deux `.trn` dans l'ordre inverse | Erreur 4305 (journal trop récent) à l'ÉTAPE 6 | ☐ |
| T17 | Remise en service automatique | `@TailLogBackup = 1` avec `@TailLogPath` vers un dossier existant mais **en lecture seule** pour le compte de service : la base passe en SINGLE_USER puis le BACKUP LOG échoue | Échec à l'ÉTAPE 2 ; la base d'origine reste intacte, ONLINE et **remise en MULTI_USER** (`SELECT user_access_desc FROM sys.databases`) | ☐ |
| T18 | Échec signalé à SQL Agent | Créer un job temporaire qui exécute un script de restauration voué à l'échec (T12) | Le job est marqué **en échec** (le `THROW` final remonte l'erreur) | ☐ |
| T19 | Serveur sans Log_Database | Sur une instance **sans** `Log_Database` (serveur de secours), lancer `full_bd_restaure_script.sql` | Avertissement « journalisation indisponible » ; **la restauration est réalisée** | ☐ |

---

## 7. Supervision

| ID | Test | Étapes | Résultat attendu | OK |
|----|------|--------|------------------|----|
| M1 | Dernières sauvegardes | Exécuter la requête « Dernière sauvegarde réussie par type » du README | Une ligne par type, dates cohérentes avec le planning | ☐ |
| M2 | Échecs | Exécuter la requête « Échecs et exécutions interrompues » du README | Les tests d'erreur des sections 3 et 5 apparaissent | ☐ |

---

## 8. Répétition générale (avant production)

- [ ] **G1** — Suivre la procédure « Test de restauration périodique » du README de bout en bout, avec la dernière chaîne réelle FULL + DIFF + LOG.
- [ ] **G2** — Mesurer la durée totale (`RestoreExecutionLog.DurationSeconds`) : c'est le **RTO réel**. Le noter dans le README.
- [ ] **G3** — Vérifier avec les utilisateurs métier que les données restaurées sont cohérentes (quelques contrôles fonctionnels dans l'application Atlantis).
- [ ] **G4** — Nettoyer : supprimer les bases de test, les fichiers de `TAILLOG\`, le login `test_orphelin`, les jobs temporaires.

---

## Récapitulatif

| Section | Tests | OK | KO | Remarques |
|---------|-------|----|----|-----------|
| 0. Préparation | P1–P5 | | | |
| 1. Installation | I1–I8 | | | |
| 2. Sauvegardes nominales | S1–S7 | | | |
| 3. Sauvegardes en erreur | E1–E10 | | | |
| 4. Purge | R1–R6 | | | |
| 5. Jobs et alertes | J1–J6 | | | |
| 6. Restauration | T1–T19 | | | |
| 7. Supervision | M1–M2 | | | |
| 8. Répétition générale | G1–G4 | | | |

Testé par : ______________________  Date : ____/____/______  Instance : ______________________
