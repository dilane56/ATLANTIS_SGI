-- =====================================================
-- SCRIPT DE RESTAURATION - VERSION CORRIGÉE
-- =====================================================

USE [master];
GO

-- Déclaration des variables
DECLARE @DatabaseName NVARCHAR(128) = 'stage_management_db';
DECLARE @BackupFilePath NVARCHAR(500) = 'C:\Backups\StageManagementBackup\stage_management_db_28-07-2026_10H36M35S_FULL.bak';
--exemple 'C:\Backups\StageManagementBackup\stage_management_db_28-07-2026_10H36M35S_FULL.bak'

PRINT '═══════════════════════════════════════════════════════════';
PRINT 'DÉBUT DE LA RESTAURATION';
PRINT '═══════════════════════════════════════════════════════════';
PRINT 'Base: ' + @DatabaseName;
PRINT 'Fichier: ' + @BackupFilePath;
PRINT '───────────────────────────────────────────────────────────';
PRINT '';

BEGIN TRY
    -- ÉTAPE 1: Vérifier que le fichier existe
    PRINT '[ÉTAPE 1] Vérification du fichier...';
    RESTORE VERIFYONLY FROM DISK = @BackupFilePath;
    PRINT '✓ Fichier valide!';
    PRINT '';

    -- ÉTAPE 2: Mettre la base en mode SINGLE_USER
    PRINT '[ÉTAPE 2] Mise en mode mono-utilisateur...';
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
    BEGIN
        EXEC ('ALTER DATABASE [' + @DatabaseName + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');
        PRINT '✓ Base en mode mono-utilisateur';
    END
    ELSE
    BEGIN
        PRINT 'ℹ Base n''existe pas encore, pas besoin de SINGLE_USER';
    END
    PRINT '';

    -- ÉTAPE 3: Restaurer la base de données
    PRINT '[ÉTAPE 3] Restauration en cours...';
    DECLARE @RestoreSQL NVARCHAR(MAX);
    SET @RestoreSQL = 'RESTORE DATABASE [' + @DatabaseName + '] 
                       FROM DISK = ''' + @BackupFilePath + ''' 
                       WITH REPLACE, RECOVERY, STATS = 10;';
    EXEC sp_executesql @RestoreSQL;
    PRINT '✓ Base restaurée avec succès!';
    PRINT '';

    -- ÉTAPE 4: Remettre en mode MULTI_USER
    PRINT '[ÉTAPE 4] Remise en mode multi-utilisateur...';
    EXEC ('ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;');
    PRINT '✓ Base en mode multi-utilisateur';
    PRINT '';

    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✓ RESTAURATION RÉUSSIE!';
    PRINT '═══════════════════════════════════════════════════════════';

END TRY
BEGIN CATCH
    PRINT '';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT '✗ ERREUR LORS DE LA RESTAURATION!';
    PRINT '═══════════════════════════════════════════════════════════';
    PRINT 'Erreur: ' + ERROR_MESSAGE();
    PRINT 'Numéro: ' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
    PRINT 'Ligne: ' + CAST(ERROR_LINE() AS NVARCHAR(10));
    PRINT '';

    -- Essayer de remettre en mode MULTI_USER
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName)
        BEGIN
            EXEC ('ALTER DATABASE [' + @DatabaseName + '] SET MULTI_USER;');
            PRINT 'Base remise en mode multi-utilisateur.';
        END
    END TRY
    BEGIN CATCH
        PRINT 'Impossible de remettre en mode multi-utilisateur.';
    END CATCH;

    -- Relancer l'erreur pour que l'appelant (ex. job SQL Agent) voie l'échec
    THROW;

END CATCH

GO