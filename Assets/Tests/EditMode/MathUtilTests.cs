using NUnit.Framework;

namespace Game.Tests
{
    public class MathUtilTests
    {
        [TestCase(5, 0, 10, 5)]
        [TestCase(-1, 0, 10, 0)]
        [TestCase(11, 0, 10, 10)]
        public void Clamp_ReturnsValueWithinRange(int value, int min, int max, int expected)
        {
            Assert.AreEqual(expected, MathUtil.Clamp(value, min, max));
        }
    }
}
