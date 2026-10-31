namespace Game
{
    /// <summary>
    /// Sample pure-logic utility (no UnityEngine dependency) so EditMode tests have a target.
    /// Replace or delete once real gameplay code exists.
    /// </summary>
    public static class MathUtil
    {
        public static int Clamp(int value, int min, int max)
        {
            if (value < min) return min;
            if (value > max) return max;
            return value;
        }
    }
}
