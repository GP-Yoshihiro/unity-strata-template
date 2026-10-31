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
            var go = new GameObject("Bootstrap");
            go.AddComponent<GameBootstrap>();
            LogAssert.Expect(LogType.Log, new System.Text.RegularExpressions.Regex(@"\[GameBootstrap\] Started"));

            yield return null;

            Assert.IsTrue(go != null);
            Object.Destroy(go);
        }
    }
}
