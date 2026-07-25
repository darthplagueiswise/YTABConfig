// YTColdConfig
// Functions: 2
// Source: fixture/YouTube

//======================================================================
// -[YTColdConfig zebraFlag] @ 0x100001000
//======================================================================
bool __cdecl -[YTColdConfig zebraFlag](YTColdConfig *self, SEL a2)
{
  unsigned int v4;
  id v9;
  if ( hasExperimentFlags(self) )
  {
    if ( (v9 = objc_msgSend(self, "objectForKey:", 45789453)) != nullptr )
      LOBYTE(v4) = (unsigned __int8)objc_msgSend(v9, "booleanFlagValue");
    else
      LOBYTE(v4) = 0;
  }
  else
  {
    LOBYTE(v4) = 0;
  }
  return v4;
}

//======================================================================
// -[YTColdConfig notBoolean] @ 0x100001100
//======================================================================
signed __int64 __cdecl -[YTColdConfig notBoolean](YTColdConfig *self, SEL a2)
{
  return 7;
}
