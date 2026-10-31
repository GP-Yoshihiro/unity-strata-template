using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Game.Tests
{
    public class BootstrapPlayModeTests
    {
        [UnityTest]
        public IEnumerator Bootstrap_SurvivesFirstFrame()
        {
            // Register the expectation before Awake() logs it (AddComponent runs Awake immediately).
            LogAssert.Expect(LogType.Log, new System.Text.RegularExpressions.Regex(@"\[GameBootstrap\] Started"));
            var go = new GameObject("Bootstrap");
            go.AddComponent<GameBootstrap>();

            yield return null;

            Assert.IsTrue(go != null);
            Object.Destroy(go);
        }
    }
}
