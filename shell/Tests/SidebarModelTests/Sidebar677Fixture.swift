import Foundation

/// sidebar.json as build 677 writes it: written by 677's own `SidebarModel`
/// (commit 195aebe8), with a symbol, an emoji and a default avatar, three
/// profiles, five spaces and a pinned tab with an emoji icon.
enum Sidebar677Fixture {
    static let profileIDs = (
        personal: UUID(uuidString: "31D34213-2DB2-4080-9CDF-375DC55DE083")!,
        akilu: UUID(uuidString: "38F27236-D4E0-4550-87CF-DCA809BA60C6")!,
        akliu: UUID(uuidString: "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37")!
    )

    static let json = #"""
{
  "activeProfileID" : "31D34213-2DB2-4080-9CDF-375DC55DE083",
  "activeSpaceID" : "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B",
  "archivedLittleArcWindows" : [

  ],
  "archivedTabs" : [

  ],
  "autoArchiveThresholdByProfile" : [

  ],
  "boostLibrariesByProfileID" : [
    "38F27236-D4E0-4550-87CF-DCA809BA60C6",
    {
      "approvedScriptHashes" : [

      ],
      "approvedStyleHashes" : [

      ],
      "installations" : [

      ],
      "masterEnabled" : true,
      "packages" : [

      ],
      "profileID" : "38F27236-D4E0-4550-87CF-DCA809BA60C6"
    },
    "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37",
    {
      "approvedScriptHashes" : [

      ],
      "approvedStyleHashes" : [

      ],
      "installations" : [

      ],
      "masterEnabled" : true,
      "packages" : [

      ],
      "profileID" : "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37"
    },
    "31D34213-2DB2-4080-9CDF-375DC55DE083",
    {
      "approvedScriptHashes" : [

      ],
      "approvedStyleHashes" : [

      ],
      "installations" : [

      ],
      "masterEnabled" : true,
      "packages" : [

      ],
      "profileID" : "31D34213-2DB2-4080-9CDF-375DC55DE083"
    }
  ],
  "capturesByID" : [

  ],
  "closedTabStack" : {
    "records" : [

    ]
  },
  "commandBarUsageBumps" : {

  },
  "easelRefsByID" : [

  ],
  "expandedFolderIDs" : [

  ],
  "foldersByID" : [

  ],
  "journalPersistedTail" : [
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "insertSpace" : {
          "id" : "F16270D0-4A7F-4C6B-8D58-C00F611C5990",
          "sortRank" : "U"
        }
      },
      "sequence" : 1,
      "timestamp" : 816160659.376754
    },
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "insertSpace" : {
          "id" : "C5B2810E-598D-46F8-ACA6-D2E22AB93933",
          "sortRank" : "V"
        }
      },
      "sequence" : 2,
      "timestamp" : 816160659.376859
    },
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "insertSpace" : {
          "id" : "D3EB4460-5D23-476F-B81C-E0EC6E10A829",
          "sortRank" : "W"
        }
      },
      "sequence" : 3,
      "timestamp" : 816160659.37693
    },
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "insertSpace" : {
          "id" : "2265A3CD-78C6-40F2-AEEA-1A5CC7949129",
          "sortRank" : "X"
        }
      },
      "sequence" : 4,
      "timestamp" : 816160659.37696
    },
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "insertItem" : {
          "container" : "pinned",
          "id" : "87F6EFB1-9E39-4E23-BC35-997513FD6323",
          "sortRank" : "U",
          "spaceID" : "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B"
        }
      },
      "sequence" : 5,
      "timestamp" : 816160659.377129
    },
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "upsertItem" : {
          "id" : "87F6EFB1-9E39-4E23-BC35-997513FD6323"
        }
      },
      "sequence" : 6,
      "timestamp" : 816160659.377495
    },
    {
      "deviceID" : "05917C9F-8496-4030-9F1B-81FE7C4D6402",
      "mutation" : {
        "upsertSpace" : {
          "id" : "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B"
        }
      },
      "sequence" : 7,
      "timestamp" : 816160659.377641
    }
  ],
  "lastActiveSpaceByProfile" : [
    "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37",
    "C5B2810E-598D-46F8-ACA6-D2E22AB93933",
    "31D34213-2DB2-4080-9CDF-375DC55DE083",
    "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B",
    "38F27236-D4E0-4550-87CF-DCA809BA60C6",
    "F16270D0-4A7F-4C6B-8D58-C00F611C5990"
  ],
  "lastFlushedSequence" : 0,
  "littleArcWindows" : [

  ],
  "profiles" : [
    {
      "avatar" : {
        "kind" : {
          "sfSymbol" : {
            "name" : "briefcase.fill"
          }
        }
      },
      "id" : "31D34213-2DB2-4080-9CDF-375DC55DE083",
      "name" : "Personal",
      "themeColor" : {
        "blue" : 0.9460784313725491,
        "gradientColors" : [
          {
            "blue" : 0.8725490196078431,
            "green" : 0.8725490196078431,
            "red" : 0.9460784313725491
          }
        ],
        "green" : 0.8137254901960784,
        "red" : 0.8088235294117647
      }
    },
    {
      "avatar" : {
        "kind" : {
          "emoji" : {
            "_0" : "💖"
          }
        }
      },
      "id" : "38F27236-D4E0-4550-87CF-DCA809BA60C6",
      "name" : "Akilu",
      "themeColor" : {
        "blue" : 0.55,
        "green" : 0.72,
        "red" : 0.25
      }
    },
    {
      "avatar" : {
        "kind" : {
          "sfSymbol" : {
            "name" : "person.fill"
          }
        }
      },
      "id" : "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37",
      "name" : "akliu",
      "themeColor" : {
        "blue" : 0.9460784313725491,
        "gradientColors" : [
          {
            "blue" : 0.8725490196078431,
            "green" : 0.8725490196078431,
            "red" : 0.9460784313725491
          }
        ],
        "green" : 0.8137254901960784,
        "red" : 0.8088235294117647
      }
    }
  ],
  "schemaVersion" : 10,
  "selectedItemID" : null,
  "selectionBySpace" : [

  ],
  "spaceContainers" : [
    "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B",
    {
      "pinned" : {
        "childIDs" : [
          "87F6EFB1-9E39-4E23-BC35-997513FD6323"
        ],
        "id" : "8CC2CA50-84BF-4553-A306-F4BA47EB1ED8",
        "kind" : {
          "spaceItems" : {
            "section" : "pinned",
            "spaceID" : "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B"
          }
        },
        "unpinnedShared" : false
      },
      "unpinned" : {
        "childIDs" : [

        ],
        "id" : "4E8A013D-3C0A-4C3E-88B9-AB39F3C4F0F1",
        "kind" : {
          "spaceItems" : {
            "section" : "unpinned",
            "spaceID" : "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B"
          }
        },
        "unpinnedShared" : false
      }
    },
    "D3EB4460-5D23-476F-B81C-E0EC6E10A829",
    {
      "pinned" : {
        "childIDs" : [

        ],
        "id" : "F04F3025-9477-4106-91C4-6B16CE26F0BE",
        "kind" : {
          "spaceItems" : {
            "section" : "pinned",
            "spaceID" : "D3EB4460-5D23-476F-B81C-E0EC6E10A829"
          }
        },
        "unpinnedShared" : false
      },
      "unpinned" : {
        "childIDs" : [

        ],
        "id" : "BA2FD7C6-FE05-41BC-A3D2-1CF9CC6114EA",
        "kind" : {
          "spaceItems" : {
            "section" : "unpinned",
            "spaceID" : "D3EB4460-5D23-476F-B81C-E0EC6E10A829"
          }
        },
        "unpinnedShared" : false
      }
    },
    "2265A3CD-78C6-40F2-AEEA-1A5CC7949129",
    {
      "pinned" : {
        "childIDs" : [

        ],
        "id" : "B7B6C228-E8D1-4EC6-B25D-EF0E348140AC",
        "kind" : {
          "spaceItems" : {
            "section" : "pinned",
            "spaceID" : "2265A3CD-78C6-40F2-AEEA-1A5CC7949129"
          }
        },
        "unpinnedShared" : false
      },
      "unpinned" : {
        "childIDs" : [

        ],
        "id" : "38C6832B-13D8-4B19-A2DF-1E8D22951898",
        "kind" : {
          "spaceItems" : {
            "section" : "unpinned",
            "spaceID" : "2265A3CD-78C6-40F2-AEEA-1A5CC7949129"
          }
        },
        "unpinnedShared" : false
      }
    },
    "C5B2810E-598D-46F8-ACA6-D2E22AB93933",
    {
      "pinned" : {
        "childIDs" : [

        ],
        "id" : "C926A3A1-97DD-4AB8-8B30-7B2F29C38FA4",
        "kind" : {
          "spaceItems" : {
            "section" : "pinned",
            "spaceID" : "C5B2810E-598D-46F8-ACA6-D2E22AB93933"
          }
        },
        "unpinnedShared" : false
      },
      "unpinned" : {
        "childIDs" : [

        ],
        "id" : "CF5939B3-FB11-42DC-B701-6C04B88466C5",
        "kind" : {
          "spaceItems" : {
            "section" : "unpinned",
            "spaceID" : "C5B2810E-598D-46F8-ACA6-D2E22AB93933"
          }
        },
        "unpinnedShared" : false
      }
    },
    "F16270D0-4A7F-4C6B-8D58-C00F611C5990",
    {
      "pinned" : {
        "childIDs" : [

        ],
        "id" : "8FDC2DC0-D196-4A2C-BE5A-78F121CA6853",
        "kind" : {
          "spaceItems" : {
            "section" : "pinned",
            "spaceID" : "F16270D0-4A7F-4C6B-8D58-C00F611C5990"
          }
        },
        "unpinnedShared" : false
      },
      "unpinned" : {
        "childIDs" : [

        ],
        "id" : "8B550AF9-7839-480C-8D0A-676548D1912A",
        "kind" : {
          "spaceItems" : {
            "section" : "unpinned",
            "spaceID" : "F16270D0-4A7F-4C6B-8D58-C00F611C5990"
          }
        },
        "unpinnedShared" : false
      }
    }
  ],
  "spaces" : [
    {
      "iconName" : "circle.fill",
      "id" : "1D6AD7D8-F0DB-43DE-8292-450D5ADA588B",
      "name" : "Main",
      "pinnedContainerID" : "8CC2CA50-84BF-4553-A306-F4BA47EB1ED8",
      "profileID" : "31D34213-2DB2-4080-9CDF-375DC55DE083",
      "sortRank" : "",
      "theme" : {
        "blue" : 0.9460784313725491,
        "gradientColors" : [
          {
            "blue" : 0.8725490196078431,
            "green" : 0.8725490196078431,
            "red" : 0.9460784313725491
          }
        ],
        "green" : 0.8137254901960784,
        "red" : 0.8088235294117647
      },
      "unpinnedContainerID" : "4E8A013D-3C0A-4C3E-88B9-AB39F3C4F0F1",
      "unpinnedShared" : false
    },
    {
      "iconName" : "circle.fill",
      "id" : "F16270D0-4A7F-4C6B-8D58-C00F611C5990",
      "name" : "Space 1",
      "pinnedContainerID" : "8FDC2DC0-D196-4A2C-BE5A-78F121CA6853",
      "profileID" : "38F27236-D4E0-4550-87CF-DCA809BA60C6",
      "sortRank" : "U",
      "theme" : {
        "blue" : 0.55,
        "green" : 0.72,
        "red" : 0.25
      },
      "unpinnedContainerID" : "8B550AF9-7839-480C-8D0A-676548D1912A",
      "unpinnedShared" : false
    },
    {
      "iconName" : "circle.fill",
      "id" : "C5B2810E-598D-46F8-ACA6-D2E22AB93933",
      "name" : "Space 1",
      "pinnedContainerID" : "C926A3A1-97DD-4AB8-8B30-7B2F29C38FA4",
      "profileID" : "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37",
      "sortRank" : "V",
      "theme" : {
        "blue" : 0.9460784313725491,
        "gradientColors" : [
          {
            "blue" : 0.8725490196078431,
            "green" : 0.8725490196078431,
            "red" : 0.9460784313725491
          }
        ],
        "green" : 0.8137254901960784,
        "red" : 0.8088235294117647
      },
      "unpinnedContainerID" : "CF5939B3-FB11-42DC-B701-6C04B88466C5",
      "unpinnedShared" : false
    },
    {
      "iconName" : "circle.fill",
      "id" : "D3EB4460-5D23-476F-B81C-E0EC6E10A829",
      "name" : "Second",
      "pinnedContainerID" : "F04F3025-9477-4106-91C4-6B16CE26F0BE",
      "profileID" : "31D34213-2DB2-4080-9CDF-375DC55DE083",
      "sortRank" : "W",
      "theme" : {
        "blue" : 0.9460784313725491,
        "gradientColors" : [
          {
            "blue" : 0.8725490196078431,
            "green" : 0.8725490196078431,
            "red" : 0.9460784313725491
          }
        ],
        "green" : 0.8137254901960784,
        "red" : 0.8088235294117647
      },
      "unpinnedContainerID" : "BA2FD7C6-FE05-41BC-A3D2-1CF9CC6114EA",
      "unpinnedShared" : false
    },
    {
      "iconName" : "circle.fill",
      "id" : "2265A3CD-78C6-40F2-AEEA-1A5CC7949129",
      "name" : "Akilu 2",
      "pinnedContainerID" : "B7B6C228-E8D1-4EC6-B25D-EF0E348140AC",
      "profileID" : "38F27236-D4E0-4550-87CF-DCA809BA60C6",
      "sortRank" : "X",
      "theme" : {
        "blue" : 0.9460784313725491,
        "gradientColors" : [
          {
            "blue" : 0.8725490196078431,
            "green" : 0.8725490196078431,
            "red" : 0.9460784313725491
          }
        ],
        "green" : 0.8137254901960784,
        "red" : 0.8088235294117647
      },
      "unpinnedContainerID" : "38C6832B-13D8-4B19-A2DF-1E8D22951898",
      "unpinnedShared" : false
    }
  ],
  "splitsByID" : [

  ],
  "tabsByID" : [
    "87F6EFB1-9E39-4E23-BC35-997513FD6323",
    {
      "customIcon" : {
        "emoji" : {
          "_0" : "🦊"
        }
      },
      "faviconToken" : "E",
      "id" : "87F6EFB1-9E39-4E23-BC35-997513FD6323",
      "isUnread" : false,
      "kind" : "pinned",
      "lastActiveAt" : 816160659.376994,
      "savedTitle" : "Example",
      "savedURL" : "https:\/\/example.com",
      "sortRank" : "U",
      "title" : "Example",
      "url" : "https:\/\/example.com"
    }
  ],
  "topAppsContainer" : {
    "childIDs" : [

    ],
    "id" : "39644C39-5AC2-487B-BC3E-D0B32BCDDBEB",
    "kind" : {
      "topApps" : {

      }
    },
    "unpinnedShared" : false
  },
  "topAppsContainersByProfileID" : [
    "38F27236-D4E0-4550-87CF-DCA809BA60C6",
    {
      "childIDs" : [

      ],
      "id" : "DAB38C4D-A723-428E-B1E5-9EDBE4EA1123",
      "kind" : {
        "topApps" : {

        }
      },
      "unpinnedShared" : false
    },
    "FC9BE491-84CF-4E6B-A4D3-4F3917C62F37",
    {
      "childIDs" : [

      ],
      "id" : "7FD36E9D-6856-41E5-BCF3-8088462E77E0",
      "kind" : {
        "topApps" : {

        }
      },
      "unpinnedShared" : false
    },
    "31D34213-2DB2-4080-9CDF-375DC55DE083",
    {
      "childIDs" : [

      ],
      "id" : "39644C39-5AC2-487B-BC3E-D0B32BCDDBEB",
      "kind" : {
        "topApps" : {

        }
      },
      "unpinnedShared" : false
    }
  ]
}
"""#
}
