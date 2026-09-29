--Bascule vers la base master (nécessaire pour les opérations système)
USE [master];
GO
-- Declaration des variables
DECLARE @DatabaseName NVARCHAR(128) = 'nom de la bd';
DECLARE @BackupFilePath NVARCHAR(500) = 'bd_src_path';
DECLARE @SQL NVARCHAR(MAX);

BEGIN TRY

    --Met la base en mode mono-utilisateur pour fermer toutes les connexions
    --(ALTER DATABASE n'accepte pas de variable : passage par du SQL dynamique)
    IF DB_ID(@DatabaseName) IS NOT NULL
    BEGIN
        --Annule les transactions en cours et ferme les connexions immédiatement
        SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
        EXEC sp_executesql @SQL;
    END;

    --Restaure la base de données depuis le fichier .bak
    RESTORE DATABASE @DatabaseName
    FROM DISK = @BackupFilePath
    WITH REPLACE, RECOVERY, STATS = 10;

    SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET MULTI_USER;';
    EXEC sp_executesql @SQL;

    PRINT '✓ Restauration réussie!';

END TRY
BEGIN CATCH

    PRINT '✗ Erreur : ' + ERROR_MESSAGE();

    -- Essayer de remettre en mode MULTI_USER
    BEGIN TRY
        IF DB_ID(@DatabaseName) IS NOT NULL
        BEGIN
            SET @SQL = N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET MULTI_USER;';
            EXEC sp_executesql @SQL;
        END;
    END TRY
    BEGIN CATCH
        PRINT 'Impossible de remettre en mode multi-utilisateur.';
    END CATCH;

    THROW;

END CATCH;
GO
