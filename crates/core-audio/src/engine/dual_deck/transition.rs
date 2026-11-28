//! Lock-free packed RT-to-relay transition events.

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RtTransitionKind {
    GaplessFlip = 1,
    CrossRateDrain = 2,
    ManualSkipFlip = 3,
    ManualSkipDrain = 4,
    MismatchCrossfadeFlip = 5,
    MismatchDrain = 6,
}

impl RtTransitionKind {
    #[inline]
    fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::GaplessFlip),
            2 => Some(Self::CrossRateDrain),
            3 => Some(Self::ManualSkipFlip),
            4 => Some(Self::ManualSkipDrain),
            5 => Some(Self::MismatchCrossfadeFlip),
            6 => Some(Self::MismatchDrain),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RtTransitionEvent {
    pub(crate) kind: RtTransitionKind,
    pub(crate) from_deck: u8,
    pub(crate) to_deck: u8,
    pub(crate) to_deck_gen: u64,
}

impl RtTransitionEvent {
    #[inline]
    pub(super) fn pack(self) -> u64 {
        ((self.kind as u64) & 0xFF)
            | (((self.from_deck as u64) & 0xFF) << 8)
            | (((self.to_deck as u64) & 0xFF) << 16)
            | ((self.to_deck_gen & 0xFF_FFFF_FFFF) << 24)
    }

    #[inline]
    pub(super) fn unpack(raw: u64) -> Option<Self> {
        let kind = RtTransitionKind::from_u8((raw & 0xFF) as u8)?;
        Some(Self {
            kind,
            from_deck: ((raw >> 8) & 0xFF) as u8,
            to_deck: ((raw >> 16) & 0xFF) as u8,
            to_deck_gen: raw >> 24,
        })
    }
}
