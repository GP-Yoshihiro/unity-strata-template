using UnityEngine;

namespace Game
{
    /// <summary>
    /// Entry point placed in the first scene. Keep it thin: wire services, then hand off.
    /// </summary>
    public sealed class GameBootstrap : MonoBehaviour
    {
        public static string Version => Application.version;

        private void Awake()
        {
            DontDestroyOnLoad(gameObject);
            Debug.Log($"[GameBootstrap] Started v{Version}");
        }
    }
}
