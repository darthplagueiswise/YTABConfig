// YTHotConfig
// Functions: 1
// Source: fixture/YouTube

//======================================================================
// -[YTHotConfig middleFlag] @ 0x100003000
//======================================================================
bool __cdecl -[YTHotConfig middleFlag](YTHotConfig *self, SEL a2)
{
  unsigned __int8 v4;
  if ( objc_msgSend(self, "hasMiddleFlag") )
    v4 = (unsigned __int8)objc_msgSend(self, "middleFlag");
  else
    v4 = 1;
  return v4;
}
