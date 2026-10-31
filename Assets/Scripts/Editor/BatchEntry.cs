using System;
using UnityEditor;
using UnityEditor.PackageManager;
using UnityEngine;

namespace Game.Editor
{
    /// <summary>
    /// Static entry points for `Unity -batchmode -executeMethod ...` (see tools/unity.ps1).
    /// AI agents must use these instead of touching .meta files directly.
    /// </summary>
    public static class BatchEntry
    {
        /// <summary>Import/refresh assets so Unity (re)generates .meta files, then exit.</summary>
        public static void Refresh()
        {
            AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
            Debug.Log("[BatchEntry] AssetDatabase refreshed");
        }

        /// <summary>
        /// Move an asset keeping its GUID. Usage:
        /// -executeMethod Game.Editor.BatchEntry.MoveAsset -from Assets/A.cs -to Assets/B/A.cs
        /// </summary>
        public static void MoveAsset()
        {
            var from = GetArg("-from");
            var to = GetArg("-to");
            var error = AssetDatabase.MoveAsset(from, to);
            if (!string.IsNullOrEmpty(error))
            {
                Debug.LogError($"[BatchEntry] MoveAsset failed: {error}");
                EditorApplication.Exit(1);
            }
        }

        /// <summary>Delete an asset together with its .meta. Usage: -executeMethod Game.Editor.BatchEntry.DeleteAsset -path Assets/X.cs</summary>
        public static void DeleteAsset()
        {
            var path = GetArg("-path");
            if (!AssetDatabase.DeleteAsset(path))
            {
                Debug.LogError($"[BatchEntry] DeleteAsset failed: {path}");
                EditorApplication.Exit(1);
            }
        }

        /// <summary>
        /// Add packages by name (Unity picks the version recommended for this editor) and exit when done.
        /// Run WITHOUT -quit, the request is asynchronous. Usage:
        /// -executeMethod Game.Editor.BatchEntry.AddPackages -packages com.unity.inputsystem,com.unity.cinemachine
        /// </summary>
        public static void AddPackages()
        {
            var ids = GetArg("-packages").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
            var request = Client.AddAndRemove(ids, null);
            EditorApplication.update += () =>
            {
                if (!request.IsCompleted) return;
                if (request.Status == StatusCode.Success)
                {
                    Debug.Log($"[BatchEntry] Packages added: {string.Join(", ", ids)}");
                    EditorApplication.Exit(0);
                }
                else
                {
                    Debug.LogError($"[BatchEntry] AddPackages failed: {request.Error?.message}");
                    EditorApplication.Exit(1);
                }
            };
        }

        private static string GetArg(string name)
        {
            var args = Environment.GetCommandLineArgs();
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == name) return args[i + 1];
            }
            throw new ArgumentException($"Missing command line argument {name}");
        }
    }
}
